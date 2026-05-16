const state = {
  token: localStorage.getItem("minimalist_token") || "",
  view: "overview",
  cache: {}
};

const titles = {
  overview: ["总览", "服务、节点和旁路由状态"],
  nodes: ["节点管理", "导入、启停、测速、改名和删除手动节点"],
  config: ["配置管理", "宿主机接管、LAN 网段和控制面配置"],
  rules: ["规则管理", "自定义规则和 ACL 规则"],
  service: ["控制启停", "服务、运行配置和路由规则"],
  logs: ["日志诊断", "journalctl 快照和错误过滤"],
  core: ["核心升级", "官方 alpha mihomo-core 单次升级"]
};

const $ = (selector) => document.querySelector(selector);

document.addEventListener("DOMContentLoaded", () => {
  bindShell();
  const queryToken = new URLSearchParams(location.search).get("token");
  if (queryToken) {
    state.token = queryToken;
    localStorage.setItem("minimalist_token", queryToken);
    history.replaceState(null, "", location.pathname);
  }
  if (state.token) {
    showApp();
    loadView("overview");
  } else {
    showLogin();
  }
});

function bindShell() {
  $("#login-form").addEventListener("submit", (event) => {
    event.preventDefault();
    state.token = $("#login-token").value.trim();
    localStorage.setItem("minimalist_token", state.token);
    showApp();
    loadView("overview");
  });

  $("#logout").addEventListener("click", () => {
    localStorage.removeItem("minimalist_token");
    state.token = "";
    showLogin();
  });

  $("#refresh").addEventListener("click", () => loadView(state.view));

  document.querySelectorAll(".nav button").forEach((button) => {
    button.addEventListener("click", () => loadView(button.dataset.view));
  });
}

function showLogin() {
  $("#login").classList.remove("hidden");
  $("#app").classList.add("hidden");
}

function showApp() {
  $("#login").classList.add("hidden");
  $("#app").classList.remove("hidden");
}

async function api(path, options = {}) {
  const headers = {
    "X-Minimalist-Token": state.token,
    ...(options.headers || {})
  };
  if (options.body && typeof options.body !== "string") {
    headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(options.body);
  }
  const response = await fetch(path, { ...options, headers });
  const payload = await response.json().catch(() => ({ ok: false, error: "invalid json response" }));
  if (response.status === 401) {
    showNotice("Token 无效或已过期。");
    localStorage.removeItem("minimalist_token");
    showLogin();
    throw new Error("unauthorized");
  }
  if (!payload.ok) {
    throw new Error(payload.error || "request failed");
  }
  return payload;
}

async function action(path, body, message) {
  try {
    const payload = await api(path, { method: "POST", body: body || {} });
    const output = payload.output ? `\n${payload.output}` : "";
    showNotice(`${message || "操作完成"}${output}`);
    await loadView(state.view);
  } catch (error) {
    showNotice(`操作失败: ${error.message}`);
  }
}

function showNotice(text) {
  const box = $("#notice");
  box.textContent = text;
  box.classList.remove("hidden");
}

function clearNotice() {
  $("#notice").classList.add("hidden");
  $("#notice").textContent = "";
}

async function loadView(view) {
  state.view = view;
  clearNotice();
  document.querySelectorAll(".nav button").forEach((button) => {
    button.classList.toggle("active", button.dataset.view === view);
  });
  document.querySelectorAll(".view").forEach((section) => {
    section.classList.toggle("hidden", section.id !== view);
  });
  $("#view-title").textContent = titles[view][0];
  $("#view-subtitle").textContent = titles[view][1];

  try {
    if (view === "overview") await renderOverview();
    if (view === "nodes") await renderNodes();
    if (view === "config") await renderConfig();
    if (view === "rules") await renderRules();
    if (view === "service") renderService();
    if (view === "logs") renderLogs();
    if (view === "core") renderCore();
  } catch (error) {
    showNotice(`加载失败: ${error.message}`);
  }
}

async function renderOverview() {
  const payload = await api("/api/overview");
  const data = payload.data;
  state.cache.overview = data;
  $("#overview").innerHTML = `
    <div class="grid cols-4">
      ${stat("服务", data.snapshot.ServiceState, data.snapshot.ServiceState === "running" ? "ok" : "warn")}
      ${stat("节点", `${data.snapshot.ManualEnabled}/${data.snapshot.ManualTotal}`, data.snapshot.NodeState === "ready" ? "ok" : "warn")}
      ${stat("宿主机接管", data.snapshot.HostProxyState, data.snapshot.HostProxyState === "off" ? "ok" : "warn")}
      ${stat("Cutover", data.cutover_ready ? "ready" : "blocked", data.cutover_ready ? "ok" : "bad")}
    </div>
    <div class="grid cols-3" style="margin-top:14px">
      <div class="panel">
        <h2>控制面</h2>
        <p>${escapeHTML(data.config.controller_bind_address)}:${data.config.controller_port}</p>
        <p class="hint">Mixed ${data.config.mixed_port} / DNS ${data.config.dns_port} / TProxy ${data.config.tproxy_port}</p>
      </div>
      <div class="panel">
        <h2>运行资产</h2>
        <p class="${data.runtime_assets.missing.length ? "bad" : "ok"}">${data.runtime_assets.missing.length ? data.runtime_assets.missing.join(", ") : "ready"}</p>
        <p class="hint">Country.mmdb、GeoSite.dat、ui/</p>
      </div>
      <div class="panel">
        <h2>订阅增强项</h2>
        <p>${data.subscriptions.enabled}/${data.subscriptions.total} enabled, ${data.subscriptions.ready} ready</p>
        <p class="hint">主路径仍只看启用的手动节点。</p>
      </div>
    </div>`;
}

function stat(label, value, className) {
  return `<div class="panel stat"><span>${label}</span><strong class="${className}">${escapeHTML(String(value))}</strong></div>`;
}

async function renderNodes() {
  const payload = await api("/api/nodes");
  const rows = payload.data || [];
  $("#nodes").innerHTML = `
    <div class="panel">
      <h2>节点列表</h2>
      <div class="table-wrap">
        <table>
          <thead><tr><th>ID</th><th>状态</th><th>来源</th><th>名称</th><th>指纹</th><th>操作</th></tr></thead>
          <tbody>${rows.map(nodeRow).join("") || emptyRow(6, "暂无节点")}</tbody>
        </table>
      </div>
    </div>
    <div class="panel" style="margin-top:14px">
      <h2>导入节点</h2>
      <label class="wide">节点链接
        <textarea id="node-links" placeholder="vless://..."></textarea>
      </label>
      <div class="actions" style="margin-top:12px">
        <button id="import-nodes">导入</button>
      </div>
    </div>`;

  $("#import-nodes").addEventListener("click", () => {
    action("/api/nodes/import", { links: $("#node-links").value }, "节点导入完成");
  });
  document.querySelectorAll("[data-node-action]").forEach((button) => {
    button.addEventListener("click", () => runNodeAction(button));
  });
}

function nodeRow(node) {
  const canEdit = node.source === "manual";
  return `<tr>
    <td>${node.index}</td>
    <td class="${node.enabled ? "ok" : "warn"}">${node.enabled ? "启用" : "停用"}</td>
    <td>${escapeHTML(node.source)}</td>
    <td>${escapeHTML(node.name)}</td>
    <td>${escapeHTML(node.uri_preview || "")}</td>
    <td><div class="actions">
      <button class="secondary" data-node-action="test" data-index="${node.index}">测速</button>
      <button class="secondary" data-node-action="${node.enabled ? "disable" : "enable"}" data-index="${node.index}" ${canEdit ? "" : "disabled"}>${node.enabled ? "停用" : "启用"}</button>
      <button class="secondary" data-node-action="rename" data-index="${node.index}" data-name="${escapeAttr(node.name)}" ${canEdit ? "" : "disabled"}>改名</button>
      <button class="danger" data-node-action="remove" data-index="${node.index}" ${canEdit ? "" : "disabled"}>删除</button>
    </div></td>
  </tr>`;
}

function runNodeAction(button) {
  const index = button.dataset.index;
  const nodeAction = button.dataset.nodeAction;
  if (nodeAction === "rename") {
    const name = prompt("新名称", button.dataset.name || "");
    if (!name) return;
    action(`/api/nodes/${index}/rename`, { name }, "节点已改名");
    return;
  }
  if (nodeAction === "remove" && !confirm("确认删除该节点？")) return;
  action(`/api/nodes/${index}/${nodeAction}`, {}, "节点操作完成");
}

async function renderConfig() {
  const payload = await api("/api/config");
  const cfg = payload.data;
  $("#config").innerHTML = `
    <div class="panel">
      <h2>配置</h2>
      <div class="form-grid">
        ${input("controller_bind_address", "控制面绑定地址", cfg.controller_bind_address)}
        ${input("core_amd64_cpu_level", "amd64 CPU level", cfg.core_amd64_cpu_level || "")}
        ${textarea("lan_cidrs", "LAN 网段", (cfg.lan_cidrs || []).join("\\n"))}
        ${textarea("lan_allowed_cidrs", "显式代理允许网段", (cfg.lan_allowed_cidrs || []).join("\\n"))}
        ${textarea("lan_disallowed_cidrs", "显式代理禁止网段", (cfg.lan_disallowed_cidrs || []).join("\\n"))}
        <label>控制面 CORS private network
          <select id="cors_allow_private_network">
            <option value="false" ${cfg.cors_allow_private_network ? "" : "selected"}>false</option>
            <option value="true" ${cfg.cors_allow_private_network ? "selected" : ""}>true</option>
          </select>
        </label>
        <label>宿主机接管
          <select id="proxy_host_output">
            <option value="false" ${cfg.proxy_host_output ? "" : "selected"}>关闭</option>
            <option value="true" ${cfg.proxy_host_output ? "selected" : ""}>开启</option>
          </select>
        </label>
      </div>
      <div class="actions" style="margin-top:14px">
        <button id="save-config">保存配置</button>
        <button id="render-config" class="secondary">重新渲染</button>
        <button id="restart-after-config" class="secondary">重启服务</button>
      </div>
    </div>`;

  $("#save-config").addEventListener("click", () => {
    const hostProxy = $("#proxy_host_output").value === "true";
    if (hostProxy && !confirm("开启宿主机接管会影响 NAS 自身流量，确认继续？")) return;
    action("/api/config", {
      controller_bind_address: $("#controller_bind_address").value,
      core_amd64_cpu_level: $("#core_amd64_cpu_level").value,
      lan_cidrs: lines("#lan_cidrs"),
      lan_allowed_cidrs: lines("#lan_allowed_cidrs"),
      lan_disallowed_cidrs: lines("#lan_disallowed_cidrs"),
      cors_allow_private_network: $("#cors_allow_private_network").value === "true",
      proxy_host_output: hostProxy
    }, "配置已保存");
  });
  $("#render-config").addEventListener("click", () => action("/api/config/render", {}, "运行配置已渲染"));
  $("#restart-after-config").addEventListener("click", () => {
    if (confirm("确认重启 minimalist.service？")) action("/api/service/restart", {}, "服务已重启");
  });
}

async function renderRules() {
  const [rules, acl] = await Promise.all([
    api("/api/rules?scope=rules"),
    api("/api/rules?scope=acl")
  ]);
  $("#rules").innerHTML = `
    <div class="grid cols-3">
      <div class="panel">
        <h2>新增规则</h2>
        <div class="grid">
          <label>类型 <input id="rule-kind" value="domain" /></label>
          <label>匹配 <input id="rule-pattern" placeholder="example.com" /></label>
          <label>目标 <input id="rule-target" value="PROXY" /></label>
          <label>范围
            <select id="rule-scope"><option value="rules">自定义规则</option><option value="acl">ACL</option></select>
          </label>
          <button id="add-rule">添加</button>
        </div>
      </div>
      <div class="panel" style="grid-column: span 2">
        <h2>自定义规则</h2>
        ${rulesTable(rules.data)}
        <h2 style="margin-top:18px">ACL 规则</h2>
        ${rulesTable(acl.data)}
      </div>
    </div>`;
  $("#add-rule").addEventListener("click", () => {
    action("/api/rules", {
      scope: $("#rule-scope").value,
      kind: $("#rule-kind").value,
      pattern: $("#rule-pattern").value,
      target: $("#rule-target").value
    }, "规则已添加");
  });
  document.querySelectorAll("[data-rule-remove]").forEach((button) => {
    button.addEventListener("click", () => {
      if (confirm("确认删除该规则？")) {
        action(`/api/rules/${button.dataset.index}/remove?scope=${button.dataset.scope}`, {}, "规则已删除");
      }
    });
  });
}

function rulesTable(rows) {
  return `<div class="table-wrap"><table>
    <thead><tr><th>ID</th><th>类型</th><th>匹配</th><th>目标</th><th>操作</th></tr></thead>
    <tbody>${(rows || []).map((rule) => `<tr>
      <td>${rule.index}</td><td>${escapeHTML(rule.kind)}</td><td>${escapeHTML(rule.pattern)}</td><td>${escapeHTML(rule.target)}</td>
      <td><button class="danger" data-rule-remove="1" data-index="${rule.index}" data-scope="${rule.scope}">删除</button></td>
    </tr>`).join("") || emptyRow(5, "暂无规则")}</tbody>
  </table></div>`;
}

function renderService() {
  $("#service").innerHTML = `
    <div class="panel">
      <h2>服务动作</h2>
      <div class="actions">
        <button data-service="start">启动</button>
        <button data-service="restart" class="secondary">重启</button>
        <button data-service="stop" class="danger">停止</button>
        <button data-service="apply-rules" class="secondary">应用规则</button>
        <button data-service="clear-rules" class="danger">清理规则</button>
      </div>
    </div>`;
  document.querySelectorAll("[data-service]").forEach((button) => {
    button.addEventListener("click", () => {
      const dangerous = ["stop", "clear-rules"].includes(button.dataset.service);
      if (dangerous && !confirm("确认执行该高风险动作？")) return;
      action(`/api/service/${button.dataset.service}`, {}, "服务动作完成");
    });
  });
}

function renderLogs() {
  $("#logs").innerHTML = `
    <div class="panel">
      <h2>日志快照</h2>
      <div class="form-grid">
        <label>目标
          <select id="log-target"><option value="">minimalist.service</option><option value="mihomo">mihomo-core</option></select>
        </label>
        <label>行数 <input id="log-lines" type="number" value="80" min="1" max="1000" /></label>
        <label>时间窗口 <input id="log-since" value="30 minutes ago" /></label>
        <label>过滤
          <select id="log-errors"><option value="0">全部</option><option value="1">warning/error</option></select>
        </label>
      </div>
      <div class="actions" style="margin-top:14px"><button id="load-logs">读取日志</button></div>
      <pre id="log-output" class="terminal" style="margin-top:14px"></pre>
    </div>`;
  $("#load-logs").addEventListener("click", async () => {
    try {
      const query = new URLSearchParams({
        target: $("#log-target").value,
        lines: $("#log-lines").value,
        since: $("#log-since").value,
        errors: $("#log-errors").value
      });
      const payload = await api(`/api/logs?${query.toString()}`);
      $("#log-output").textContent = payload.output || "无输出";
    } catch (error) {
      $("#log-output").textContent = `读取失败: ${error.message}`;
    }
  });
}

function renderCore() {
  $("#core").innerHTML = `
    <div class="panel">
      <h2>核心升级</h2>
      <p class="hint">该动作会从官方 alpha release 下载并替换 mihomo-core，成功后重启 minimalist.service。失败时后端会按现有回滚逻辑恢复旧 core。</p>
      <div class="actions" style="margin-top:14px">
        <button id="core-upgrade" class="danger">执行 alpha 升级</button>
      </div>
      <pre id="core-output" class="terminal" style="margin-top:14px"></pre>
    </div>`;
  $("#core-upgrade").addEventListener("click", async () => {
    const typed = prompt("输入 upgrade 确认核心升级");
    if (typed !== "upgrade") return;
    $("#core-output").textContent = "升级中，请等待...";
    try {
      const payload = await api("/api/core/upgrade", { method: "POST", body: {} });
      $("#core-output").textContent = payload.output || "升级完成";
    } catch (error) {
      $("#core-output").textContent = `升级失败: ${error.message}`;
    }
  });
}

function input(id, label, value) {
  return `<label>${label}<input id="${id}" value="${escapeAttr(value || "")}" /></label>`;
}

function textarea(id, label, value) {
  return `<label class="wide">${label}<textarea id="${id}">${escapeHTML(value || "")}</textarea></label>`;
}

function lines(selector) {
  return $(selector).value.split("\n").map((line) => line.trim()).filter(Boolean);
}

function emptyRow(cols, text) {
  return `<tr><td colspan="${cols}" class="hint">${text}</td></tr>`;
}

function escapeHTML(value) {
  return String(value).replace(/[&<>"']/g, (char) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#039;"
  }[char]));
}

function escapeAttr(value) {
  return escapeHTML(value).replace(/`/g, "&#096;");
}
