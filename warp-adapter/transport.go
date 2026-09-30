// Adapted from ViRb3/wgcf commit ace873cbaa618365beebde5790a7fb3481e5a211.
// Copyright (c) 2020 ViRb3. MIT; see LICENSE.wgcf.
package main

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"io"
	"mime"
	"net"
	"net/http"
	"strings"
	"time"

	"fmt"
	utls "github.com/refraction-networking/utls"
)

const (
	ApiUrl                  = "https://api.cloudflareclient.com"
	ApiVersion              = "v0a5641"
	warpTLSHandshakeTimeout = 10 * time.Second
)

var (
	DefaultHeaders = map[string]string{
		"User-Agent":        "1.1.1.1/6.38.9-5641 (Android 16.0.0)",
		"CF-Client-Version": "a-6.38.9-5641",
	}
	warpSessionCache = utls.NewLRUClientSessionCache(64)
	warpDialer       = &net.Dialer{
		Timeout:   30 * time.Second,
		KeepAlive: 30 * time.Second,
	}
	warpTLSConfig = &tls.Config{
		MinVersion: tls.VersionTLS12,
		MaxVersion: tls.VersionTLS12,
	}
	DefaultTransport = &http.Transport{
		// TLSClientConfig supplies verification settings to dialWarpTLS. The
		// ClientHello itself is assembled by uTLS to match the Android app.
		TLSClientConfig:   warpTLSConfig,
		DialTLSContext:    dialWarpTLS,
		ForceAttemptHTTP2: false,
		// A CONNECT proxy makes net/http bypass DialTLSContext for the target
		// handshake. Stay direct so every API connection uses the WARP hello.
		MaxIdleConns:          100,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   warpTLSHandshakeTimeout,
		ExpectContinueTimeout: 1 * time.Second,
	}
)

type cloudflareResponseTransport struct {
	base http.RoundTripper
}

func (t cloudflareResponseTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	// Match the OkHttp request headers emitted by the Android client.
	request.Header.Del("Accept")
	request.Header.Set("Connection", "Keep-Alive")
	requestContentType, _, requestContentTypeErr := mime.ParseMediaType(request.Header.Get("Content-Type"))
	if requestContentTypeErr == nil && requestContentType == "application/json" {
		request.Header.Set("Content-Type", "application/json; charset=UTF-8")
	}

	response, err := t.base.RoundTrip(request)
	if err != nil || response == nil || !strings.HasSuffix(request.URL.Path, "/client_config") {
		return response, err
	}

	contentType, _, parseErr := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if parseErr == nil && contentType == "text/plain" {
		// The Android endpoint returns JSON while labelling it as text/plain.
		// The generated OpenAPI decoder dispatches exclusively on this header.
		response.Header.Set("Content-Type", "application/json")
	}
	return response, nil
}

func dialWarpTLS(ctx context.Context, network, address string) (net.Conn, error) {
	rawConn, err := warpDialer.DialContext(ctx, network, address)
	if err != nil {
		return nil, err
	}

	serverName, _, err := net.SplitHostPort(address)
	if err != nil {
		rawConn.Close()
		return nil, fmt.Errorf("split TLS address: %w", err)
	}

	handshakeCtx, cancel := context.WithTimeout(ctx, warpTLSHandshakeTimeout)
	defer cancel()
	tlsConn, err := handshakeWarpTLS(handshakeCtx, rawConn, serverName, warpTLSConfig)
	if err != nil {
		rawConn.Close()
		return nil, err
	}
	return tlsConn, nil
}

func handshakeWarpTLS(ctx context.Context, rawConn net.Conn, serverName string, config *tls.Config) (*utls.UConn, error) {
	if config.ServerName != "" {
		serverName = config.ServerName
	}
	uConfig := &utls.Config{
		ServerName:            serverName,
		RootCAs:               config.RootCAs,
		InsecureSkipVerify:    config.InsecureSkipVerify,
		VerifyPeerCertificate: config.VerifyPeerCertificate,
		ClientSessionCache:    warpSessionCache,
		MinVersion:            utls.VersionTLS12,
		MaxVersion:            utls.VersionTLS12,
		NextProtos:            []string{"http/1.1"},
		KeyLogWriter:          config.KeyLogWriter,
	}
	uConn := utls.UClient(rawConn, uConfig, utls.HelloCustom)
	if err := uConn.ApplyPreset(warpClientHelloSpec()); err != nil {
		return nil, fmt.Errorf("apply WARP TLS fingerprint: %w", err)
	}

	// Conscrypt leaves the session ID empty on a fresh TLS 1.2 connection.
	// uTLS normally generates one for every custom ClientHello, so clear it
	// before session lookup and restore it only when a cached ticket is used.
	uConn.HandshakeState.Hello.SessionId = nil
	if err := uConn.BuildHandshakeState(); err != nil {
		return nil, fmt.Errorf("build WARP TLS ClientHello: %w", err)
	}
	if warpSessionTicketPresent(uConn) {
		sessionID := make([]byte, 32)
		if _, err := io.ReadFull(rand.Reader, sessionID); err != nil {
			return nil, fmt.Errorf("generate TLS session ID: %w", err)
		}
		uConn.HandshakeState.Hello.SessionId = sessionID
		if err := uConn.MarshalClientHello(); err != nil {
			return nil, fmt.Errorf("marshal resumed WARP TLS ClientHello: %w", err)
		}
	}

	if err := uConn.HandshakeContext(ctx); err != nil {
		return nil, fmt.Errorf("WARP TLS handshake: %w", err)
	}
	return uConn, nil
}

func warpSessionTicketPresent(conn *utls.UConn) bool {
	for _, extension := range conn.Extensions {
		if ticket, ok := extension.(*utls.SessionTicketExtension); ok {
			return len(ticket.Ticket) != 0
		}
	}
	return false
}

func warpClientHelloSpec() *utls.ClientHelloSpec {
	return &utls.ClientHelloSpec{
		TLSVersMin: utls.VersionTLS12,
		TLSVersMax: utls.VersionTLS12,
		CipherSuites: []uint16{
			utls.TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
			utls.TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
		},
		CompressionMethods: []uint8{0},
		Extensions: []utls.TLSExtension{
			&utls.SNIExtension{},
			&utls.ExtendedMasterSecretExtension{},
			&utls.RenegotiationInfoExtension{Renegotiation: utls.RenegotiateNever},
			&utls.SupportedCurvesExtension{Curves: []utls.CurveID{
				utls.X25519,
				utls.CurveP256,
				utls.CurveP384,
			}},
			&utls.SupportedPointsExtension{SupportedPoints: []uint8{0}},
			&utls.SessionTicketExtension{},
			&utls.ALPNExtension{AlpnProtocols: []string{"http/1.1"}},
			&utls.StatusRequestExtension{},
			&utls.SignatureAlgorithmsExtension{SupportedSignatureAlgorithms: []utls.SignatureScheme{
				utls.ECDSAWithP256AndSHA256,
				utls.PSSWithSHA256,
				utls.PKCS1WithSHA256,
				utls.ECDSAWithP384AndSHA384,
				utls.PSSWithSHA384,
				utls.PKCS1WithSHA384,
				utls.PSSWithSHA512,
				utls.PKCS1WithSHA512,
				utls.PKCS1WithSHA1,
			}},
			&utls.UtlsPaddingExtension{GetPaddingLen: utls.BoringPaddingStyle},
		},
	}
}
