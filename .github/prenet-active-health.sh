# Authenticated loopback listeners are served by the RUNNING core. They never
# create a second WireGuard device with the active private key.
render_warp_health_config() {
    local port4="$1" port6="$2" port_route="$3" secret_file="$4"
    validate_port_value "$port4" && validate_port_value "$port6" && \
        validate_port_value "$port_route" || return 1
    [ "$port4" != "$port6" ] && [ "$port4" != "$port_route" ] && [ "$port6" != "$port_route" ] || return 1
    [ -f "$secret_file" ] && [ ! -L "$secret_file" ] || return 1
    jq -n --argjson p4 "$port4" --argjson p6 "$port6" --argjson pr "$port_route" --rawfile secret "$secret_file" '
      ($secret | gsub("[\\r\\n]"; "")) as $password |
      if ($password | test("^[a-f0-9]{48}$")) then
      {inbounds:[
        {type:"mixed",tag:"prenet-health4",listen:"127.0.0.1",listen_port:$p4,users:[{username:"prenet-health",password:$password}]},
        {type:"mixed",tag:"prenet-health6",listen:"127.0.0.1",listen_port:$p6,users:[{username:"prenet-health",password:$password}]},
        {type:"mixed",tag:"prenet-health-route",listen:"127.0.0.1",listen_port:$pr,users:[{username:"prenet-health",password:$password}]}
      ],route:{rules:[
        {inbound:["prenet-health4"],action:"resolve",server:"local",strategy:"ipv4_only"},
        {inbound:["prenet-health6"],action:"resolve",server:"local",strategy:"ipv6_only"},
        {inbound:["prenet-health4","prenet-health6"],action:"route",outbound:"wireguard-out"}
      ]}}
      else error("invalid health secret") end'
}

warp_health_config_is_valid() {
    local file="${conf_dir}/00-prenet-health.json"
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    jq -e '
      (keys == ["inbounds","route"]) and
      (.inbounds | length == 3) and
      ([.inbounds[].tag] == ["prenet-health4","prenet-health6","prenet-health-route"]) and
      ([.inbounds[].listen_port] | unique | length == 3) and
      all(.inbounds[]; .type == "mixed" and .listen == "127.0.0.1" and
        (.listen_port | type == "number" and . >= 1024 and . <= 65535 and . == floor) and
        (.users | length == 1) and .users[0].username == "prenet-health" and
        (.users[0].password | type == "string" and test("^[a-f0-9]{48}$"))) and
      ([.inbounds[].users[0].password] | unique | length == 1) and
      (.route == {rules:[
        {inbound:["prenet-health4"],action:"resolve",server:"local",strategy:"ipv4_only"},
        {inbound:["prenet-health6"],action:"resolve",server:"local",strategy:"ipv6_only"},
        {inbound:["prenet-health4","prenet-health6"],action:"route",outbound:"wireguard-out"}
      ]})
    ' "$file" >/dev/null 2>&1
}

ensure_warp_health_inbounds() {
    local health_file="${conf_dir}/00-prenet-health.json"
    if warp_health_config_is_valid; then
        chmod 600 "$health_file"
        return $?
    fi
    [ ! -e "$health_file" ] && [ ! -L "$health_file" ] || {
        red "本机健康检查配置不符合预期，未覆盖；请检查 ${health_file}" >&2
        return 1
    }
    (
        local stage='' installed=false committed=false rc=0 port attempt
        local -a ports=()
        acquire_proxy_transaction_lock_checked "$conf_dir" "WARP 健康入口初始化" || exit $?
        trap 'rc=$?; if [ "$installed" = true ] && [ "$committed" != true ]; then
            rm -f -- "$health_file" || rc=2
            restart_singbox_checked >/dev/null 2>&1 || rc=2
            singbox_service_is_stably_active || rc=2
          fi
          [ -z "$stage" ] || rm -rf -- "$stage"
          release_proxy_transaction_lock || rc=2
          exit "$rc"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        # A concurrent initializer may have finished while we waited.
        if warp_health_config_is_valid; then exit 0; fi
        [ ! -e "$health_file" ] && [ ! -L "$health_file" ] || exit 1
        singbox_service_is_active || { red "sing-box 未运行，未创建健康入口。" >&2; exit 1; }
        warp_endpoint_is_valid "$(extract_warp_endpoint "${conf_dir}/endpoints.json" 2>/dev/null)" || exit 1
        command_exists ss || { red "健康入口初始化需要 ss。" >&2; exit 1; }
        stage=$(mktemp -d "${conf_dir}/.health-stage.XXXXXX") || exit 1
        chmod 700 "$stage" || exit 1
        for ((attempt=0; attempt<30; attempt++)); do
            port=$((20000 + RANDOM % 30000))
            [[ " ${ports[*]} " != *" $port "* ]] || continue
            ss -ltnH | awk '{print $4}' | grep -Eq "(^|:)${port}$" && continue
            ports+=("$port")
            [ "${#ports[@]}" -lt 3 ] || break
        done
        [ "${#ports[@]}" -eq 3 ] || exit 1
        od -An -N24 -tx1 /dev/urandom | tr -d ' \n' > "$stage/secret" || exit 1
        render_warp_health_config "${ports[0]}" "${ports[1]}" "${ports[2]}" "$stage/secret" > "$stage/health.json" || exit 1
        chmod 600 "$stage/health.json" || exit 1
        installed=true
        mv "$stage/health.json" "$health_file" || exit 1
        if ! validate_singbox_config || ! restart_singbox_checked || ! singbox_service_is_stably_active; then
            red "健康入口初始化失败，正在撤回新增文件并恢复服务。" >&2
            exit 1
        fi
        committed=true
    )
}

start_warp_active_proxy() {
    local family="${1:-4}" tag port health_file="${conf_dir}/00-prenet-health.json"
    case "$family" in 4|6) tag="prenet-health${family}" ;; route) tag=prenet-health-route ;; *) return 1 ;; esac
    stop_warp_candidate_proxy
    ensure_warp_health_inbounds || return $?
    singbox_service_is_active || return 1
    mkdir -p "${conf_dir}/warp" && chmod 700 "${conf_dir}/warp" || return 1
    WARP_PROBE_DIR=$(mktemp -d "${conf_dir}/warp/.probe.XXXXXX") || return 1
    chmod 700 "$WARP_PROBE_DIR" || { stop_warp_candidate_proxy; return 1; }
    port=$(jq -er --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | .listen_port' "$health_file") || { stop_warp_candidate_proxy; return 1; }
    jq -r --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | "proxy-user = \"prenet-health:\(.users[0].password)\""' \
        "$health_file" > "$WARP_PROBE_DIR/curl.conf" || { stop_warp_candidate_proxy; return 1; }
    chmod 600 "$WARP_PROBE_DIR/curl.conf" || { stop_warp_candidate_proxy; return 1; }
    WARP_PROBE_PROXY="socks5h://127.0.0.1:${port}"
    WARP_PROBE_CURL_ARGS=(--config "$WARP_PROBE_DIR/curl.conf")
    WARP_PROBE_FAMILY="$family"
    WARP_PROBE_MODE=active
    # No PID is created here: both address families use the sole active endpoint.
}

show_warp_health() {
    local family rc=1
    for family in 4 6; do
        if probe_active_warp "$family"; then
            green "WARP IPv${family}: ${WARP_PROBE_IP}  ${WARP_PROBE_STATE}  ${WARP_PROBE_LOC}/${WARP_PROBE_COLO}"
            rc=0
        else
            yellow "WARP IPv${family}: 本次检查未通过（不代表另一个地址族不可用）"
        fi
    done
    yellow "以上检查经过正式 sing-box 出站；未匹配 WARP 规则的网站仍使用原出口。"
    return "$rc"
}
