use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{atomic::{AtomicBool, Ordering}, Arc};
use std::time::Instant;

use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use md5::{Digest as Md5Digest, Md5};
use reqwest::blocking::{Client, Response};
use reqwest::header::{CONTENT_LENGTH, RANGE};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::Sha384;
use tauri::{AppHandle, Emitter, State};

const RELEASE_API: &str = "https://services.api.unity.com/unity/editor/release/v1/releases";

#[derive(Clone)]
struct InstallState {
    running: Arc<AtomicBool>,
    cancel: Arc<AtomicBool>,
}

#[derive(Debug, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct VersionSummary {
    version: String,
    stream: String,
    release_date: String,
    recommended: bool,
    download_size: Option<u64>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
struct PackageInfo {
    id: String,
    name: String,
    url: String,
    kind: String,
    size: Option<u64>,
    integrity: Option<String>,
    destination: Option<String>,
    rename_from: Option<String>,
    rename_to: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Component {
    id: String,
    name: String,
    description: Option<String>,
    category: Option<String>,
    kind: String,
    url: String,
    size: Option<u64>,
    integrity: Option<String>,
    destination: Option<String>,
    rename_from: Option<String>,
    rename_to: Option<String>,
    required: bool,
    hidden: bool,
    pre_selected: bool,
    #[serde(default)]
    sub_modules: Vec<Component>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
struct ReleaseDetail {
    version: String,
    revision: String,
    stream: String,
    release_date: String,
    recommended: bool,
    editor: PackageInfo,
    modules: Vec<Component>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InstallRequest {
    release: ReleaseDetail,
    selected_ids: Vec<String>,
    destination: String,
    cache_dir: String,
    offline: bool,
}

#[derive(Debug, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct ProgressEvent {
    phase: String,
    item_id: Option<String>,
    item_name: Option<String>,
    downloaded: u64,
    total: Option<u64>,
    completed_items: usize,
    total_items: usize,
    status: String,
    message: Option<String>,
}

#[derive(Debug, Serialize)]
struct CacheStatus {
    exists: bool,
    size: u64,
    complete: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AppDefaults {
    cache_dir: String,
    install_dir: String,
}

fn default_cache_dir() -> PathBuf {
    dirs::cache_dir()
        .or_else(dirs::data_local_dir)
        .unwrap_or_else(|| PathBuf::from("."))
        .join("UnityHubLite")
        .join("packages")
}

fn default_install_dir() -> PathBuf {
    #[cfg(windows)]
    {
        PathBuf::from(r"C:\Unity")
    }
    #[cfg(not(windows))]
    {
        dirs::home_dir().unwrap_or_else(|| PathBuf::from("."))
            .join("Unity")
    }
}

fn text_field(value: &Value, key: &str) -> String {
    value.get(key).and_then(Value::as_str).unwrap_or_default().to_string()
}

fn optional_text(value: &Value, key: &str) -> Option<String> {
    let text = text_field(value, key);
    if text.trim().is_empty() { None } else { Some(text) }
}

fn size_field(value: &Value, key: &str) -> Option<u64> {
    let raw = value.get(key)?;
    raw.as_u64().or_else(|| raw.get("value").and_then(Value::as_u64))
}

fn selected_download(release: &Value) -> Option<&Value> {
    release.get("downloads")?.as_array()?.iter().find(|download| {
        text_field(download, "platform").eq_ignore_ascii_case("WINDOWS")
            && text_field(download, "architecture").eq_ignore_ascii_case("X86_64")
    })
}

fn parse_component(value: &Value) -> Component {
    let sub_modules = value.get("subModules")
        .and_then(Value::as_array)
        .map(|items| items.iter().map(parse_component).collect())
        .unwrap_or_default();
    let rename = value.get("extractedPathRename");
    Component {
        id: text_field(value, "id"),
        name: text_field(value, "name"),
        description: optional_text(value, "description"),
        category: optional_text(value, "category"),
        kind: text_field(value, "type"),
        url: text_field(value, "url"),
        size: size_field(value, "downloadSize"),
        integrity: optional_text(value, "integrity"),
        destination: optional_text(value, "destination"),
        rename_from: rename.and_then(|v| optional_text(v, "from")),
        rename_to: rename.and_then(|v| optional_text(v, "to")),
        required: value.get("required").and_then(Value::as_bool).unwrap_or(false),
        hidden: value.get("hidden").and_then(Value::as_bool).unwrap_or(false),
        pre_selected: value.get("preSelected").and_then(Value::as_bool).unwrap_or(false),
        sub_modules,
    }
}

fn parse_release(value: &Value) -> Result<ReleaseDetail, String> {
    let download = selected_download(value).ok_or_else(|| "该版本没有 Windows x86_64 安装包".to_string())?;
    let version = text_field(value, "version");
    let revision = optional_text(value, "shortRevision")
        .or_else(|| optional_text(value, "revision"))
        .unwrap_or_default();
    let modules = download.get("modules")
        .and_then(Value::as_array)
        .map(|items| items.iter().map(parse_component).collect())
        .unwrap_or_default();
    Ok(ReleaseDetail {
        version: version.clone(),
        revision,
        stream: text_field(value, "stream"),
        release_date: text_field(value, "releaseDate"),
        recommended: value.get("recommended").and_then(Value::as_bool).unwrap_or(false),
        editor: PackageInfo {
            id: "editor".to_string(),
            name: format!("Unity Editor {version}"),
            url: text_field(download, "url"),
            kind: text_field(download, "type"),
            size: size_field(download, "downloadSize"),
            integrity: optional_text(download, "integrity"),
            destination: Some("{UNITY_PATH}".to_string()),
            rename_from: None,
            rename_to: None,
        },
        modules,
    })
}

fn api_client() -> Result<Client, String> {
    Client::builder()
        .user_agent("UnityHubLite/0.1")
        .build()
        .map_err(|error| format!("创建网络客户端失败：{error}"))
}

fn fetch_json(url: &str, query: &[(&str, &str)]) -> Result<Value, String> {
    let client = api_client()?;
    client.get(url).query(query).send()
        .map_err(|error| format!("请求 Unity 发布接口失败：{error}"))?
        .error_for_status()
        .map_err(|error| format!("Unity 发布接口返回错误：{error}"))?
        .json::<Value>()
        .map_err(|error| format!("解析 Unity 发布数据失败：{error}"))
}

fn release_values(value: Value) -> Vec<Value> {
    value.get("results")
        .and_then(Value::as_array)
        .cloned()
        .or_else(|| value.as_array().cloned())
        .unwrap_or_default()
}

fn read_cached_release(cache_dir: &Path, version: &str) -> Option<ReleaseDetail> {
    let path = cache_dir.join(version).join("release.json");
    let data = fs::read_to_string(path).ok()?;
    serde_json::from_str(&data).ok()
}

fn write_cached_release(cache_dir: &Path, release: &ReleaseDetail) -> Result<(), String> {
    let directory = cache_dir.join(&release.version);
    fs::create_dir_all(&directory).map_err(|error| format!("创建缓存目录失败：{error}"))?;
    let path = directory.join("release.json");
    let data = serde_json::to_string_pretty(release).map_err(|error| format!("保存版本元数据失败：{error}"))?;
    fs::write(path, data).map_err(|error| format!("保存版本元数据失败：{error}"))
}

fn package_filename(package: &PackageInfo) -> String {
    let candidate = package.url.split('?').next().unwrap_or_default()
        .rsplit('/').next().unwrap_or_default()
        .trim();
    if candidate.contains('.') && !candidate.ends_with('.') {
        return candidate.to_string();
    }
    if let Some(language) = package.id.strip_prefix("language-") {
        return format!("{language}.po");
    }
    format!("{}.{}", package.id.replace(['/', '\\'], "_"), package.kind.to_lowercase())
}

fn component_as_package(component: &Component) -> PackageInfo {
    PackageInfo {
        id: component.id.clone(),
        name: component.name.clone(),
        url: component.url.clone(),
        kind: component.kind.clone(),
        size: component.size,
        integrity: component.integrity.clone(),
        destination: component.destination.clone(),
        rename_from: component.rename_from.clone(),
        rename_to: component.rename_to.clone(),
    }
}

fn flatten_components<'a>(nodes: &'a [Component], result: &mut Vec<&'a Component>) {
    for node in nodes {
        result.push(node);
        flatten_components(&node.sub_modules, result);
    }
}

fn selected_packages(release: &ReleaseDetail, selected_ids: &[String]) -> Vec<PackageInfo> {
    let selected: HashSet<&str> = selected_ids.iter().map(String::as_str).collect();
    let mut packages = vec![release.editor.clone()];
    fn add_selected(node: &Component, selected: &HashSet<&str>, packages: &mut Vec<PackageInfo>) {
        if selected.contains(node.id.as_str()) {
            packages.push(component_as_package(node));
            for child in &node.sub_modules {
                packages.push(component_as_package(child));
                add_descendants(child, packages);
            }
        } else {
            for child in &node.sub_modules {
                add_selected(child, selected, packages);
            }
        }
    }
    fn add_descendants(node: &Component, packages: &mut Vec<PackageInfo>) {
        for child in &node.sub_modules {
            packages.push(component_as_package(child));
            add_descendants(child, packages);
        }
    }
    for node in &release.modules {
        add_selected(node, &selected, &mut packages);
    }
    packages
}

fn emit_progress(app: &AppHandle, event: ProgressEvent) {
    let _ = app.emit("install-progress", event);
}

fn is_complete(path: &Path, expected: Option<u64>) -> bool {
    if !path.is_file() { return false; }
    match (expected, fs::metadata(path).ok()) {
        (Some(expected), Some(metadata)) => metadata.len() == expected,
        _ => true,
    }
}

fn verify_integrity(path: &Path, expected_size: Option<u64>, integrity: Option<&str>) -> Result<(), String> {
    if let Some(expected) = expected_size {
        let actual = fs::metadata(path).map_err(|error| error.to_string())?.len();
        if actual != expected {
            return Err(format!("文件大小不匹配（期望 {expected}，实际 {actual}）"));
        }
    }
    let Some(integrity) = integrity.filter(|value| !value.is_empty()) else { return Ok(()); };
    let (algorithm, encoded) = integrity.split_once('-').unwrap_or(("", ""));
    let expected = BASE64.decode(encoded).map_err(|error| format!("解析完整性校验值失败：{error}"))?;
    let mut file = File::open(path).map_err(|error| format!("打开下载文件失败：{error}"))?;
    let mut buffer = [0u8; 1024 * 1024];
    match algorithm.to_ascii_lowercase().as_str() {
        "md5" => {
            let mut hasher = Md5::new();
            loop {
                let read = file.read(&mut buffer).map_err(|error| error.to_string())?;
                if read == 0 { break; }
                hasher.update(&buffer[..read]);
            }
            if hasher.finalize().as_slice() != expected.as_slice() { return Err("MD5 校验失败".to_string()); }
        }
        "sha384" => {
            let mut hasher = Sha384::new();
            loop {
                let read = file.read(&mut buffer).map_err(|error| error.to_string())?;
                if read == 0 { break; }
                hasher.update(&buffer[..read]);
            }
            if hasher.finalize().as_slice() != expected.as_slice() { return Err("SHA-384 校验失败".to_string()); }
        }
        _ => return Err(format!("不支持的完整性算法：{algorithm}")),
    }
    Ok(())
}

fn content_length(response: &Response) -> Option<u64> {
    response.headers().get(CONTENT_LENGTH)?.to_str().ok()?.parse().ok()
}

fn find_legacy_package(package: &PackageInfo, cache_root: &Path, filename: &str) -> Option<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(parent) = cache_root.parent() {
        candidates.push(parent.join(filename));
    }
    if let Ok(directory) = std::env::current_dir() {
        candidates.push(directory.join(filename));
    }
    if let Ok(executable) = std::env::current_exe() {
        if let Some(parent) = executable.parent() {
            candidates.push(parent.join(filename));
        }
    }
    candidates.into_iter().find(|candidate| {
        is_complete(candidate, package.size)
            && verify_integrity(candidate, package.size, package.integrity.as_deref()).is_ok()
    })
}

fn download_package(
    app: &AppHandle,
    package: &PackageInfo,
    cache_root: &Path,
    offline: bool,
    cancel: &AtomicBool,
    completed_items: usize,
    total_items: usize,
) -> Result<PathBuf, String> {
    let folder = cache_root.to_path_buf();
    if !offline {
        fs::create_dir_all(&folder).map_err(|error| format!("创建下载缓存目录失败：{error}"))?;
    }
    let filename = package_filename(package);
    let target = folder.join(&filename);
    let part = folder.join(format!("{filename}.part"));
    if is_complete(&target, package.size) {
        emit_progress(app, ProgressEvent {
            phase: "download".to_string(), item_id: Some(package.id.clone()), item_name: Some(package.name.clone()),
            downloaded: package.size.unwrap_or(0), total: package.size, completed_items, total_items,
            status: "已使用本地缓存".to_string(), message: None,
        });
        return Ok(target);
    }
    // Keep compatibility with the original PowerShell tool, which stored files
    // beside the script instead of under a versioned cache directory.
    if let Some(legacy) = find_legacy_package(package, cache_root, &filename) {
        if !offline {
            fs::copy(&legacy, &target).map_err(|error| format!("复制本地缓存失败：{error}"))?;
            return Ok(target);
        }
        return Ok(legacy);
    }
    if offline {
        return Err(format!("离线缓存缺少 {}（{}）", package.name, filename));
    }

    let mut existing = fs::metadata(&part).map(|metadata| metadata.len()).unwrap_or(0);
    if let Some(expected) = package.size {
        if existing == expected {
            verify_integrity(&part, package.size, package.integrity.as_deref())?;
            fs::rename(&part, &target).map_err(|error| format!("完成缓存文件失败：{error}"))?;
            return Ok(target);
        }
        if existing > expected { fs::remove_file(&part).ok(); existing = 0; }
    }
    let client = api_client()?;
    let mut request = client.get(&package.url);
    if existing > 0 { request = request.header(RANGE, format!("bytes={existing}-")); }
    let mut response = request.send().map_err(|error| format!("下载 {} 失败：{error}", package.name))?;
    let append = existing > 0 && response.status() == reqwest::StatusCode::PARTIAL_CONTENT;
    if !response.status().is_success() {
        return Err(format!("下载 {} 返回 HTTP {}", package.name, response.status()));
    }
    if !append { existing = 0; }
    let total = if append { Some(existing + content_length(&response).unwrap_or(0)) } else { content_length(&response).or(package.size) };
    let mut output = if append {
        OpenOptions::new().create(true).append(true).open(&part)
    } else {
        OpenOptions::new().create(true).write(true).truncate(true).open(&part)
    }.map_err(|error| format!("打开缓存文件失败：{error}"))?;
    let started = Instant::now();
    let mut downloaded = existing;
    let mut buffer = [0u8; 1024 * 512];
    loop {
        if cancel.load(Ordering::Relaxed) { return Err("下载已取消，部分文件已保留".to_string()); }
        let read = response.read(&mut buffer).map_err(|error| format!("读取下载流失败：{error}"))?;
        if read == 0 { break; }
        output.write_all(&buffer[..read]).map_err(|error| format!("写入缓存失败：{error}"))?;
        downloaded += read as u64;
        let elapsed = started.elapsed().as_secs_f64().max(0.1);
        emit_progress(app, ProgressEvent {
            phase: "download".to_string(), item_id: Some(package.id.clone()), item_name: Some(package.name.clone()),
            downloaded, total, completed_items, total_items,
            status: format!("{} / {} · {:.1} MB/s", human_bytes(downloaded), total.map(human_bytes).unwrap_or_else(|| "?".to_string()), downloaded as f64 / elapsed / 1_048_576.0), message: None,
        });
    }
    output.flush().map_err(|error| format!("刷新缓存文件失败：{error}"))?;
    verify_integrity(&part, package.size, package.integrity.as_deref()).map_err(|error| {
        fs::remove_file(&part).ok();
        format!("{}：{}", package.name, error)
    })?;
    fs::rename(&part, &target).map_err(|error| format!("保存下载文件失败：{error}"))?;
    Ok(target)
}

fn human_bytes(bytes: u64) -> String {
    if bytes >= 1_073_741_824 { format!("{:.2} GB", bytes as f64 / 1_073_741_824.0) }
    else if bytes >= 1_048_576 { format!("{:.1} MB", bytes as f64 / 1_048_576.0) }
    else if bytes >= 1024 { format!("{:.1} KB", bytes as f64 / 1024.0) }
    else { format!("{bytes} B") }
}

fn resolve_path(template: Option<&str>, unity_path: &Path) -> PathBuf {
    let value = template.unwrap_or("{UNITY_PATH}").replace("{UNITY_PATH}", &unity_path.to_string_lossy());
    PathBuf::from(value)
}

fn safe_child(root: &Path, path: &Path) -> Result<(), String> {
    let root = root.canonicalize().unwrap_or_else(|_| root.to_path_buf());
    let candidate = if path.exists() { path.canonicalize() } else {
        let parent = path.parent().unwrap_or(path).canonicalize().unwrap_or_else(|_| path.parent().unwrap_or(path).to_path_buf());
        Ok(parent.join(path.file_name().unwrap_or_default()))
    }.map_err(|error| error.to_string())?;
    if !candidate.starts_with(&root) { return Err(format!("拒绝写入安装目录之外的路径：{}", candidate.display())); }
    Ok(())
}

fn extract_zip(path: &Path, destination: &Path, cancel: &AtomicBool) -> Result<(), String> {
    fs::create_dir_all(destination).map_err(|error| format!("创建解压目录失败：{error}"))?;
    let file = File::open(path).map_err(|error| format!("打开 ZIP 失败：{error}"))?;
    let mut archive = zip::ZipArchive::new(file).map_err(|error| format!("读取 ZIP 失败：{error}"))?;
    for index in 0..archive.len() {
        if cancel.load(Ordering::Relaxed) { return Err("安装已取消".to_string()); }
        let mut entry = archive.by_index(index).map_err(|error| format!("读取 ZIP 条目失败：{error}"))?;
        let Some(relative) = entry.enclosed_name() else { return Err("ZIP 包含不安全路径".to_string()); };
        let target = destination.join(relative);
        if entry.is_dir() { fs::create_dir_all(&target).map_err(|error| error.to_string())?; continue; }
        if let Some(parent) = target.parent() { fs::create_dir_all(parent).map_err(|error| error.to_string())?; }
        let mut output = File::create(&target).map_err(|error| format!("创建解压文件失败：{error}"))?;
        std::io::copy(&mut entry, &mut output).map_err(|error| format!("解压文件失败：{error}"))?;
    }
    Ok(())
}

fn install_package(package: &PackageInfo, file: &Path, unity_path: &Path, cancel: &AtomicBool) -> Result<(), String> {
    if cancel.load(Ordering::Relaxed) { return Err("安装已取消".to_string()); }
    // Unity publishes a few placeholder ZIP entries (for example the Android
    // SDK tools marker) that are intentionally not real archives.
    if package.size.is_some_and(|size| size <= 256) { return Ok(()); }
    let destination = resolve_path(package.destination.as_deref(), unity_path);
    fs::create_dir_all(&destination).map_err(|error| format!("创建安装目录失败：{error}"))?;
    match package.kind.to_ascii_uppercase().as_str() {
        "EXE" => {
            let status = Command::new(file)
                .arg("/S")
                .arg(format!("/D={}", destination.display()))
                .status()
                .map_err(|error| format!("启动安装器失败：{error}"))?;
            if !status.success() { return Err(format!("安装器退出码：{}", status.code().unwrap_or(-1))); }
        }
        "ZIP" => {
            safe_child(unity_path, &destination)?;
            extract_zip(file, &destination, cancel)?;
            if let (Some(from), Some(to)) = (&package.rename_from, &package.rename_to) {
                let source = resolve_path(Some(from), unity_path);
                let target = resolve_path(Some(to), unity_path);
                safe_child(unity_path, &source)?;
                safe_child(unity_path, &target)?;
                if source.exists() && source != target {
                    if target.exists() { fs::remove_dir_all(&target).ok(); }
                    if let Some(parent) = target.parent() { fs::create_dir_all(parent).ok(); }
                    fs::rename(source, target).map_err(|error| format!("整理解压目录失败：{error}"))?;
                }
            }
        }
        "PO" => {
            safe_child(unity_path, &destination)?;
            let filename = if let Some(language) = package.id.strip_prefix("language-") { format!("{language}.po") } else { package_filename(package) };
            fs::copy(file, destination.join(filename)).map_err(|error| format!("复制语言包失败：{error}"))?;
        }
        other => return Err(format!("不支持的安装包类型：{other}")),
    }
    Ok(())
}

fn perform_install(app: AppHandle, request: InstallRequest, state: InstallState) -> Result<(), String> {
    let cache_root = PathBuf::from(&request.cache_dir);
    let unity_path = PathBuf::from(&request.destination);
    fs::create_dir_all(&cache_root).map_err(|error| format!("创建缓存目录失败：{error}"))?;
    fs::create_dir_all(&unity_path).map_err(|error| format!("创建安装目录失败：{error}"))?;
    if !request.offline {
        write_cached_release(&cache_root, &request.release)?;
    }
    let packages = selected_packages(&request.release, &request.selected_ids);
    let total_items = packages.len();
    let mut files = Vec::with_capacity(total_items);
    for (index, package) in packages.iter().enumerate() {
        let file = download_package(&app, package, &cache_root.join(&request.release.version), request.offline, &state.cancel, index, total_items)?;
        files.push((package.clone(), file));
    }
    for (index, (package, file)) in files.iter().enumerate() {
        if state.cancel.load(Ordering::Relaxed) { return Err("安装已取消".to_string()); }
        emit_progress(&app, ProgressEvent {
            phase: "install".to_string(), item_id: Some(package.id.clone()), item_name: Some(package.name.clone()),
            downloaded: 0, total: None, completed_items: index, total_items,
            status: "正在安装".to_string(), message: None,
        });
        install_package(package, file, &unity_path, &state.cancel)?;
    }
    emit_progress(&app, ProgressEvent {
        phase: "done".to_string(), item_id: None, item_name: None, downloaded: 0, total: None,
        completed_items: total_items, total_items, status: "安装完成".to_string(),
        message: Some(format!("Unity {} 已安装到 {}", request.release.version, unity_path.display())),
    });
    Ok(())
}

#[tauri::command]
fn get_defaults() -> AppDefaults {
    AppDefaults { cache_dir: default_cache_dir().display().to_string(), install_dir: default_install_dir().display().to_string() }
}

#[tauri::command]
fn list_versions(cache_dir: Option<String>) -> Result<Vec<VersionSummary>, String> {
    let cache = cache_dir.map(PathBuf::from).unwrap_or_else(default_cache_dir);
    // Unity currently caps this endpoint's page size at 25. The latest page is
    // enough to keep startup fast while still exposing the current release streams.
    let response = fetch_json(RELEASE_API, &[("limit", "25"), ("offset", "0")]);
    let values = match response {
        Ok(value) => value,
        Err(error) => {
            let mut cached = Vec::new();
            if let Ok(entries) = fs::read_dir(&cache) {
                for entry in entries.flatten() {
                    if let Some(version) = entry.file_name().to_str() {
                        if let Some(release) = read_cached_release(&cache, version) {
                            cached.push(VersionSummary { version: release.version, stream: release.stream, release_date: release.release_date, recommended: release.recommended, download_size: release.editor.size });
                        }
                    }
                }
            }
            if cached.is_empty() { return Err(error); }
            return Ok(cached);
        }
    };
    Ok(release_values(values).iter().filter_map(|item| {
        let download = selected_download(item)?;
        Some(VersionSummary {
            version: text_field(item, "version"), stream: text_field(item, "stream"), release_date: text_field(item, "releaseDate"),
            recommended: item.get("recommended").and_then(Value::as_bool).unwrap_or(false), download_size: size_field(download, "downloadSize"),
        })
    }).collect())
}

#[tauri::command]
fn get_release(version: String, cache_dir: Option<String>) -> Result<ReleaseDetail, String> {
    let cache = cache_dir.map(PathBuf::from).unwrap_or_else(default_cache_dir);
    match fetch_json(RELEASE_API, &[("version", version.as_str())]) {
        Ok(value) => {
            let release = release_values(value).into_iter().next().ok_or_else(|| format!("找不到 Unity 版本：{version}"))
                .and_then(|value| parse_release(&value))?;
            write_cached_release(&cache, &release)?;
            Ok(release)
        }
        Err(error) => read_cached_release(&cache, &version).ok_or(error),
    }
}

#[tauri::command]
fn cache_status(release: ReleaseDetail, cache_dir: String) -> Result<HashMap<String, CacheStatus>, String> {
    let root = PathBuf::from(cache_dir).join(&release.version);
    let mut all_nodes = Vec::new();
    flatten_components(&release.modules, &mut all_nodes);
    let mut packages = vec![release.editor.clone()];
    packages.extend(all_nodes.into_iter().map(component_as_package));
    let mut result = HashMap::new();
    for package in packages {
        let filename = package_filename(&package);
        let target = root.join(&filename);
        let part = root.join(format!("{filename}.part"));
        let legacy = find_legacy_package(&package, &root, &filename);
        let size = fs::metadata(&target).map(|item| item.len()).or_else(|_| fs::metadata(&part).map(|item| item.len())).unwrap_or(0);
        result.insert(package.id, CacheStatus { exists: size > 0 || legacy.is_some(), size, complete: is_complete(&target, package.size) || legacy.is_some() });
    }
    Ok(result)
}

#[tauri::command]
fn start_install(app: AppHandle, state: State<'_, InstallState>, request: InstallRequest) -> Result<(), String> {
    if state.running.swap(true, Ordering::SeqCst) { return Err("已有安装任务正在运行".to_string()); }
    state.cancel.store(false, Ordering::SeqCst);
    let task_state = state.inner().clone();
    std::thread::spawn(move || {
        let result = perform_install(app.clone(), request, task_state.clone());
        task_state.running.store(false, Ordering::SeqCst);
        if let Err(error) = result {
            let phase = if task_state.cancel.load(Ordering::Relaxed) { "cancelled" } else { "failed" };
            emit_progress(&app, ProgressEvent { phase: phase.to_string(), item_id: None, item_name: None, downloaded: 0, total: None, completed_items: 0, total_items: 0, status: error.clone(), message: Some(error) });
        }
    });
    Ok(())
}

#[tauri::command]
fn cancel_install(state: State<'_, InstallState>) -> Result<(), String> {
    state.cancel.store(true, Ordering::SeqCst);
    Ok(())
}

fn main() {
    tauri::Builder::default()
        .manage(InstallState { running: Arc::new(AtomicBool::new(false)), cancel: Arc::new(AtomicBool::new(false)) })
        .invoke_handler(tauri::generate_handler![get_defaults, list_versions, get_release, cache_status, start_install, cancel_install])
        .run(tauri::generate_context!())
        .expect("error while running Unity Hub Lite");
}
