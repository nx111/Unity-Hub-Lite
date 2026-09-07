import { invoke } from "@tauri-apps/api/core";
import { open } from "@tauri-apps/plugin-dialog";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import "./styles.css";

type PackageKind = "EXE" | "ZIP" | "PO" | string;

interface VersionSummary {
  version: string;
  stream: string;
  releaseDate: string;
  recommended: boolean;
  downloadSize?: number;
}

function compareVersions(a: string, b: string): number {
  const parse = (value: string) => value.match(/\d+|\D+/g) ?? [];
  const left = parse(a);
  const right = parse(b);
  for (let i = 0; i < Math.max(left.length, right.length); i++) {
    const x = left[i] ?? "";
    const y = right[i] ?? "";
    if (/^\d+$/.test(x) && /^\d+$/.test(y)) {
      const difference = Number(x) - Number(y);
      if (difference !== 0) return difference;
    } else if (x !== y) {
      return x < y ? -1 : 1;
    }
  }
  return 0;
}

interface PackageInfo {
  id: string;
  name: string;
  url: string;
  kind: PackageKind;
  size?: number;
  integrity?: string;
  destination?: string;
  renameFrom?: string;
  renameTo?: string;
}

interface Component extends PackageInfo {
  description?: string;
  category?: string;
  required: boolean;
  hidden: boolean;
  preSelected: boolean;
  subModules: Component[];
}

interface ReleaseDetail {
  version: string;
  revision: string;
  stream: string;
  releaseDate: string;
  recommended: boolean;
  editor: PackageInfo;
  modules: Component[];
}

interface InstallRequest {
  release: ReleaseDetail;
  selectedIds: string[];
  uninstallIds: string[];
  destination: string;
  cacheDir: string;
  offline: boolean;
}

interface ProgressEvent {
  phase: "download" | "install" | "done" | "failed" | "cancelled" | string;
  itemId?: string;
  itemName?: string;
  downloaded: number;
  total?: number;
  completedItems: number;
  totalItems: number;
  status: string;
  message?: string;
}

interface CacheStatus {
  exists: boolean;
  size: number;
  complete: boolean;
  installed: boolean;
  uninstallable: boolean;
}

interface AppDefaults {
  cacheDir: string;
  installDir: string;
}

const state = {
  versions: [] as VersionSummary[],
  installedVersions: {} as Record<string, string>,
  selectedVersion: "",
  release: null as ReleaseDetail | null,
  selectedIds: new Set<string>(),
  pendingUninstall: new Set<string>(),
  cache: {} as Record<string, CacheStatus>,
  cacheDir: "",
  installDir: "",
  offline: false,
  loadingVersions: false,
  loadingRelease: false,
  installing: false,
  uninstalling: new Set<string>(),
  progress: null as ProgressEvent | null,
  error: "",
  logs: [] as string[],
};

let unlistenProgress: UnlistenFn | undefined;

const app = document.querySelector<HTMLDivElement>("#app")!;

function isTauri(): boolean {
  return "__TAURI_INTERNALS__" in window;
}

function escapeHtml(value: unknown): string {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function formatBytes(bytes?: number): string {
  if (!bytes || bytes <= 0) return "大小未知";
  const units = ["B", "GB", "TB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value >= 100 ? value.toFixed(0) : value >= 10 ? value.toFixed(1) : value.toFixed(2)} ${units[unit]}`;
}

function formatDate(date?: string): string {
  if (!date) return "";
  const parsed = new Date(date);
  return Number.isNaN(parsed.getTime()) ? date.slice(0, 10) : parsed.toLocaleDateString("zh-CN");
}

function allComponents(nodes: Component[], result: Component[] = []): Component[] {
  for (const node of nodes) {
    result.push(node);
    allComponents(node.subModules ?? [], result);
  }
  return result;
}

function componentById(id: string): Component | undefined {
  return state.release ? allComponents(state.release.modules).find((item) => item.id === id) : undefined;
}

function isLanguagePack(node: Component): boolean {
  return node.category?.toUpperCase() === "LANGUAGE_PACK" || node.id.toLowerCase().startsWith("language-");
}

function packageCount(): number {
  if (!state.release) return 0;
  const editorCount = state.cache.editor?.installed ? 0 : 1;
  return editorCount + [...state.selectedIds].filter((id) => componentById(id) && !state.cache[id]?.installed).length;
}

function selectedSize(): number {
  if (!state.release) return 0;
  return [...state.selectedIds]
    .filter((id) => !state.cache[id]?.installed)
    .map((id) => componentById(id)?.size ?? 0)
    .reduce((total, size) => total + size, state.cache.editor?.installed ? 0 : (state.release.editor.size ?? 0));
}

function addLog(message: string): void {
  state.logs = [...state.logs.slice(-7), message];
}

function setSelectedTree(node: Component, selected: boolean): void {
  if (selected) state.selectedIds.add(node.id);
  else state.selectedIds.delete(node.id);
  for (const child of node.subModules ?? []) setSelectedTree(child, selected);
}

async function refreshCache(): Promise<void> {
  if (!state.release || !state.cacheDir || !isTauri()) return;
  try {
    state.cache = await invoke<Record<string, CacheStatus>>("cache_status", {
      release: state.release,
      cacheDir: state.cacheDir,
      installDir: state.installDir,
    });
    // Installed components mirror their real state: always selected unless queued for uninstall.
    for (const node of allComponents(state.release.modules)) {
      if (!state.cache[node.id]?.installed) state.pendingUninstall.delete(node.id);
      else if (!state.pendingUninstall.has(node.id)) state.selectedIds.add(node.id);
    }
    render();
  } catch (error) {
    addLog(`无法读取缓存：${String(error)}`);
  }
}

async function loadDefaults(): Promise<void> {
  if (!isTauri()) {
    state.cacheDir = "%LOCALAPPDATA%\\UnityOfflineHub\\cache";
    state.installDir = "C:\\Unity";
    return;
  }
  try {
    const defaults = await invoke<AppDefaults>("get_defaults");
    state.cacheDir = defaults.cacheDir;
    state.installDir = defaults.installDir;
  } catch (error) {
    state.error = String(error);
  }
}

async function loadVersions(): Promise<void> {
  state.loadingVersions = true;
  state.error = "";
  render();
  try {
    state.versions = await invoke<VersionSummary[]>("list_versions", { cacheDir: state.cacheDir });
    state.installedVersions = isTauri()
      ? await invoke<Record<string, string>>("installed_versions", { versions: state.versions.map((item) => item.version) })
      : {};
    const installedList = Object.keys(state.installedVersions);
    const preferred = installedList.length > 0
      ? installedList.reduce((latest, version) => (compareVersions(version, latest) > 0 ? version : latest))
      : state.versions[0]?.version;
    if (!state.selectedVersion) state.selectedVersion = preferred ?? state.versions[0]?.version ?? "";
    await loadRelease(state.selectedVersion, false);
  } catch (error) {
    state.error = `版本列表加载失败：${String(error)}`;
  } finally {
    state.loadingVersions = false;
    render();
  }
}

async function loadRelease(version: string, rerender = true): Promise<void> {
  if (!version || !isTauri()) return;
  state.loadingRelease = true;
  state.error = "";
  if (rerender) render();
  try {
    state.release = await invoke<ReleaseDetail>("get_release", { version, cacheDir: state.cacheDir });
    if (isTauri()) {
      const detected = await invoke<string | null>("detect_install_dir", { version, current: state.installDir });
      if (detected) state.installDir = detected;
    }
    state.selectedIds = new Set();
    state.pendingUninstall = new Set();
    for (const component of state.release.modules) {
      if (component.preSelected || component.required) setSelectedTree(component, true);
    }
    await refreshCache();
  } catch (error) {
    state.release = null;
    state.error = `组件列表加载失败：${String(error)}`;
  } finally {
    state.loadingRelease = false;
    render();
  }
}

function renderVersionOptions(): string {
  if (state.loadingVersions) return `<option>正在读取 Unity 发布列表…</option>`;
  if (state.versions.length === 0) return `<option value="">暂无版本</option>`;
  return state.versions
    .map(
      (item) =>
        `<option value="${escapeHtml(item.version)}" ${item.version === state.selectedVersion ? "selected" : ""}>${escapeHtml(item.version)} · ${escapeHtml(item.stream || "Release")}${state.installedVersions[item.version] ? " ✓ 已安装" : ""}</option>`,
    )
    .join("");
}

function renderComponent(node: Component, depth = 0): string {
  if (node.hidden && depth === 0) return "";
  const selected = state.selectedIds.has(node.id);
  const languagePack = isLanguagePack(node);
  const cached = state.cache[node.id];
  const children = (node.subModules ?? []).map((child) => renderComponent(child, depth + 1)).join("");
  const indent = Math.min(depth, 3) * 20;
  const pending = state.pendingUninstall.has(node.id);
  const cacheLabel = pending ? "待卸载" : cached?.installed ? "已安装" : cached?.complete ? "已缓存" : cached?.exists ? "未完成" : "在线下载";
  const cacheClass = pending ? "partial" : cached?.installed ? "installed" : cached?.complete ? "ready" : cached?.exists ? "partial" : "";
  const uninstalling = state.uninstalling.has(node.id);
  const uninstall = cached?.installed && cached.uninstallable
    ? `<button class="module-action" type="button" data-uninstall-id="${escapeHtml(node.id)}" ${state.installing || uninstalling ? "disabled" : ""}>${uninstalling ? "卸载中…" : "卸载"}</button>`
    : "";
  return `
    <div class="component-row ${depth ? "nested" : ""}" style="--indent:${indent}px">
      <label class="component-check">
        <input type="checkbox" data-component-id="${escapeHtml(node.id)}" ${selected ? "checked" : ""} ${node.required ? "disabled" : ""}>
        <span class="checkmark"></span>
      </label>
      <div class="component-icon ${node.category === "PLATFORM" ? "platform" : "tool"}">${node.category === "PLATFORM" ? "◆" : "◇"}</div>
      <div class="component-copy">
        <div class="component-title">${escapeHtml(node.name || node.id)} ${node.required ? '<span class="required">必需</span>' : languagePack ? '<span class="optional">可选</span>' : ""}</div>
        <div class="component-description">${escapeHtml(node.description || node.id)}</div>
      </div>
      <div class="component-meta">
        <span>${formatBytes(node.size)}</span>
        <span class="cache-pill ${cacheClass}">${cacheLabel}</span>${uninstall}
      </div>
    </div>
    ${children}`;
}

function renderEditor(packageInfo: PackageInfo): string {
  const cached = state.cache.editor;
  const cacheLabel = cached?.installed ? "已安装" : cached?.complete ? "已缓存" : cached?.exists ? "未完成" : "在线下载";
  const cacheClass = cached?.installed ? "installed" : cached?.complete ? "ready" : cached?.exists ? "partial" : "";
  return `
    <div class="component-row">
      <label class="component-check"><input type="checkbox" checked disabled><span class="checkmark"></span></label>
      <div class="component-icon editor">U</div>
      <div class="component-copy"><div class="component-title">${escapeHtml(packageInfo.name)} <span class="required">核心</span></div><div class="component-description">Windows x86_64 Editor 安装程序</div></div>
      <div class="component-meta"><span>${formatBytes(packageInfo.size)}</span><span class="cache-pill ${cacheClass}">${cacheLabel}</span></div>
    </div>`;
}

function renderProgress(): string {
  const progress = state.progress;
  if (!progress) {
    return `<div class="progress-empty"><span class="pulse-dot"></span><span>等待开始安装</span><span class="progress-hint">中断后再次开始会从 .part 文件继续</span></div>`;
  }
  const percent = progress.total && progress.total > 0 ? Math.min(100, (progress.downloaded / progress.total) * 100) : 0;
  const overall = progress.totalItems > 0 ? (progress.completedItems / progress.totalItems) * 100 : 0;
  const label = progress.itemName || progress.message || "准备中";
  return `
    <div class="progress-heading"><span>${escapeHtml(label)}</span><strong>${progress.phase === "install" ? "安装中" : progress.phase === "uninstall" ? "卸载中" : progress.phase === "done" ? "完成" : `${percent.toFixed(1)}%`}</strong></div>
    <div class="progress-track"><span style="width:${progress.phase === "install" ? "100" : percent}%"></span></div>
    <div class="progress-subline"><span>${escapeHtml(progress.status || "")}</span><span>${progress.completedItems}/${progress.totalItems} 个文件</span></div>
    <div class="overall-track"><span style="width:${overall}%"></span></div>`;
}

function render(): void {
  const release = state.release;
  const selectedSizeText = selectedSize() ? formatBytes(selectedSize()) : "—";
  const canInstall = Boolean(release && state.installDir.trim() && !state.installing && state.uninstalling.size === 0 && (packageCount() > 0 || state.pendingUninstall.size > 0));
  app.innerHTML = `
    <div class="shell">
      <aside class="sidebar">
        <div class="brand"><div class="brand-mark">U</div><div><div class="brand-name">UNITY HUB LITE</div><div class="brand-sub">OFFLINE INSTALLER</div></div></div>
        <nav class="nav">
          <button class="nav-item active"><span class="nav-icon">▦</span>Editor 安装</button>
          <button class="nav-item muted"><span class="nav-icon">◫</span>下载缓存</button>
          <button class="nav-item muted"><span class="nav-icon">⚙</span>设置</button>
        </nav>
        <div class="sidebar-bottom">
          <div class="connection"><span class="connection-dot"></span><span>${state.offline ? "离线安装模式" : "在线，可获取最新版本"}</span></div>
          <div class="sidebar-version">Unity Hub Lite <span>0.1.0</span></div>
        </div>
      </aside>
      <main class="main-content">
        <header class="topbar"><div><div class="eyebrow">EDITOR INSTALLER</div><h1>安装 Unity Editor</h1><p>选择版本与组件，下载后可在无网络环境中重复安装。</p></div><button class="icon-button" id="refresh-button" title="刷新版本列表">↻</button></header>
        ${state.error ? `<div class="alert error"><span>!</span><span>${escapeHtml(state.error)}</span></div>` : ""}
        <section class="setup-grid">
          <div class="panel version-panel">
            <div class="panel-label">01 · 选择版本</div>
            <div class="version-select-wrap"><select id="version-select">${renderVersionOptions()}</select><span class="select-chevron">⌄</span></div>
            ${release ? `<div class="release-summary"><span class="release-badge">${escapeHtml(release.stream || "RELEASE")}</span>${release.recommended ? '<span class="recommended">推荐</span>' : ""}<span class="release-date">${formatDate(release.releaseDate)}</span><span class="release-revision">${escapeHtml(release.revision || "")}</span></div>` : `<div class="loading-copy">${state.loadingRelease ? "正在读取组件…" : "选择一个版本查看组件"}</div>`}
          </div>
          <div class="panel destination-panel">
            <div class="panel-label">安装位置</div>
            <div class="path-field"><label class="path-label" for="install-dir">Editor 目录</label><div class="path-row"><input id="install-dir" value="${escapeHtml(state.installDir)}" placeholder="例如 C:\\Unity\\6000.6.0f1" /><button class="path-button" id="browse-install" type="button" title="浏览文件夹">浏览</button></div></div>
            <div class="path-field"><label class="path-label" for="cache-dir">下载缓存</label><div class="path-row"><input id="cache-dir" value="${escapeHtml(state.cacheDir)}" placeholder="可复用的本地组件缓存目录" /><button class="path-button" id="browse-cache" type="button" title="浏览文件夹">浏览</button></div></div>
            <label class="toggle-line"><input type="checkbox" id="offline-toggle" ${state.offline ? "checked" : ""}><span class="toggle"></span><span>仅使用本地缓存（离线安装）</span></label>
          </div>
        </section>
        <section class="panel components-panel">
          <div class="components-header"><div><div class="panel-label">02 · 选择组件</div><h2>${release ? `Unity ${escapeHtml(release.version)} 组件` : "选择一个版本"}</h2></div><div class="component-summary"><strong>${state.selectedIds.size}</strong> 个组件 · ${selectedSizeText}</div></div>
          <div class="component-list">
            ${release ? renderEditor(release.editor) : ""}
            ${release ? release.modules.filter((item) => !item.hidden).map((item) => renderComponent(item)).join("") : '<div class="empty-state">组件会显示在这里</div>'}
          </div>
          <div class="components-foot"><span><span class="legend-dot"></span>已安装的组件保持选中，取消勾选即卸载</span><span>语言包可单独选择</span></div>
        </section>
        <section class="panel progress-panel"><div class="progress-title"><div><div class="panel-label">03 · 下载与安装</div><h2>安装进度</h2></div><div class="progress-mode ${state.offline ? "offline" : ""}">${state.offline ? "离线缓存" : "可断点续传"}</div></div>${renderProgress()}${state.logs.length ? `<div class="logs">${state.logs.map((log) => `<div>${escapeHtml(log)}</div>`).join("")}</div>` : ""}</section>
<footer class="action-bar"><div class="action-info"><span class="action-count">${packageCount()}</span><span>个安装包将被处理</span>${state.pendingUninstall.size ? ` <span class="action-count">${state.pendingUninstall.size}</span><span>个组件将卸载</span>` : ""}</div><button class="secondary-button" id="cancel-button" ${state.installing ? "" : "disabled"}>取消</button><button class="primary-button" id="install-button" ${canInstall ? "" : "disabled"}>${state.installing ? "处理中…" : state.offline ? "开始离线安装" : "下载并安装"}<span>→</span></button></footer>
      </main>
    </div>`;
  bindEvents();
}

function bindEvents(): void {
  document.querySelector<HTMLButtonElement>("#refresh-button")?.addEventListener("click", () => void loadVersions());
  document.querySelector<HTMLSelectElement>("#version-select")?.addEventListener("change", (event) => {
    state.selectedVersion = (event.target as HTMLSelectElement).value;
    void loadRelease(state.selectedVersion);
  });
  document.querySelector<HTMLInputElement>("#install-dir")?.addEventListener("change", (event) => {
    state.installDir = (event.target as HTMLInputElement).value;
    void refreshCache();
  });
  document.querySelector<HTMLInputElement>("#cache-dir")?.addEventListener("change", (event) => {
    state.cacheDir = (event.target as HTMLInputElement).value;
    void refreshCache();
  });
  document.querySelector<HTMLButtonElement>("#browse-install")?.addEventListener("click", () => void browseFolder("install"));
  document.querySelector<HTMLButtonElement>("#browse-cache")?.addEventListener("click", () => void browseFolder("cache"));
  document.querySelector<HTMLInputElement>("#offline-toggle")?.addEventListener("change", (event) => {
    state.offline = (event.target as HTMLInputElement).checked;
    render();
  });
  document.querySelectorAll<HTMLInputElement>("[data-component-id]").forEach((checkbox) => {
    checkbox.addEventListener("change", (event) => {
      const input = event.target as HTMLInputElement;
      const node = componentById(input.dataset.componentId || "");
      if (node) {
        if (!input.checked && state.cache[node.id]?.installed) state.pendingUninstall.add(node.id);
        if (input.checked) state.pendingUninstall.delete(node.id);
        setSelectedTree(node, input.checked);
        void refreshCache();
        render();
      }
    });
  });
  document.querySelectorAll<HTMLButtonElement>("[data-uninstall-id]").forEach((button) => {
    button.addEventListener("click", () => void uninstallModule(button.dataset.uninstallId || ""));
  });
  document.querySelector<HTMLButtonElement>("#install-button")?.addEventListener("click", () => void startInstall());
  document.querySelector<HTMLButtonElement>("#cancel-button")?.addEventListener("click", () => void cancelInstall());
}


async function browseFolder(target: "install" | "cache"): Promise<void> {
  if (!isTauri()) return;
  const current = target === "install" ? state.installDir : state.cacheDir;
  const selected = await open({ directory: true, multiple: false, defaultPath: current || undefined });
  if (typeof selected !== "string" || !selected) return;
  if (target === "install") state.installDir = selected;
  else state.cacheDir = selected;
  render();
  await refreshCache();
}

async function uninstallModule(moduleId: string): Promise<void> {
  if (!moduleId || !state.release || !isTauri() || state.installing || state.uninstalling.has(moduleId)) return;
  const node = componentById(moduleId);
  if (!node || !window.confirm(`确定卸载“${node.name || moduleId}”？`)) return;
  state.uninstalling.add(moduleId);
  state.error = "";
  render();
  try {
    await invoke("uninstall_module", {
      release: state.release,
      moduleId,
      destination: state.installDir.trim(),
    });
    addLog(`已卸载：${node.name || moduleId}`);
    await refreshCache();
  } catch (error) {
    state.error = String(error);
    addLog(`卸载失败：${String(error)}`);
  } finally {
    state.uninstalling.delete(moduleId);
    render();
  }
}

async function startInstall(): Promise<void> {
  if (!state.release || !state.installDir.trim() || state.installing || state.uninstalling.size > 0) return;
  if (!isTauri()) {
    state.error = "请使用 `npm run tauri dev` 启动桌面应用后执行安装。";
    render();
    return;
  }
  const pendingNames = [...state.pendingUninstall].map((id) => componentById(id)?.name || id);
  if (pendingNames.length > 0 && !window.confirm(`将卸载以下组件：\n${pendingNames.join("\n")}\n\n是否继续？`)) return;
  state.installing = true;
  state.error = "";
  state.progress = null;
  state.logs = [];
  addLog(state.offline ? "开始检查本地缓存…" : "开始下载组件，支持断点续传…");
  render();
  const request: InstallRequest = {
    release: state.release,
    selectedIds: [...state.selectedIds],
    uninstallIds: [...state.pendingUninstall],
    destination: state.installDir.trim(),
    cacheDir: state.cacheDir.trim(),
    offline: state.offline,
  };
  try {
    await invoke("start_install", { request });
  } catch (error) {
    state.installing = false;
    state.error = String(error);
    addLog(`安装失败：${String(error)}`);
    render();
  }
}

async function cancelInstall(): Promise<void> {
  if (!state.installing || !isTauri()) return;
  try {
    await invoke("cancel_install");
    addLog("已请求取消；未完成的 .part 文件会保留以便下次续传。");
  } catch (error) {
    state.error = String(error);
    render();
  }
}

async function setupEvents(): Promise<void> {
  if (!isTauri()) return;
  unlistenProgress = await listen<ProgressEvent>("install-progress", (event) => {
    state.progress = event.payload;
    if (["done", "failed", "cancelled"].includes(event.payload.phase)) {
      state.installing = false;
      if (event.payload.phase === "done") state.pendingUninstall.clear();
      if (event.payload.message) addLog(event.payload.message);
      if (event.payload.phase === "failed") state.error = event.payload.message || "安装失败";
      if (event.payload.phase === "done") void refreshCache();
    }
    render();
  });
}

window.addEventListener("beforeunload", () => unlistenProgress?.());

async function bootstrap(): Promise<void> {
  await loadDefaults();
  render();
  await setupEvents();
  await loadVersions();
}

void bootstrap();
