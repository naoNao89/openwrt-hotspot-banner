use std::borrow::Cow;
use std::fs;
use std::path::{Component, Path, PathBuf};

#[derive(Debug, Clone)]
pub struct Theme {
    custom_dir: PathBuf,
    default_dir: PathBuf,
}

#[derive(Debug, Clone)]
pub struct ThemeContext<'a> {
    pub title: &'a str,
    pub accept_url: &'a str,
    pub active_sessions: usize,
    pub max_active_sessions: usize,
    pub queue_retry_seconds: u64,
}

#[derive(Debug, Clone)]
pub struct ThemeAsset {
    pub body: Vec<u8>,
    pub content_type: &'static str,
}

impl Theme {
    pub fn new(custom_dir: impl Into<PathBuf>, default_dir: impl Into<PathBuf>) -> Self {
        Self {
            custom_dir: custom_dir.into(),
            default_dir: default_dir.into(),
        }
    }

    pub fn render_page(&self, file_name: &str, context: &ThemeContext<'_>) -> Option<String> {
        self.read_theme_file(file_name)
            .map(|template| render_template(&template, context))
    }

    pub fn asset(&self, path: &str) -> Option<ThemeAsset> {
        let relative_path = safe_relative_path(path)?;
        let file_path = self
            .selected_dir()
            .and_then(|dir| existing_file(dir.join(&relative_path)))?;
        let body = fs::read(&file_path).ok()?;
        let content_type = content_type_for(file_path.extension().and_then(|ext| ext.to_str()));

        Some(ThemeAsset { body, content_type })
    }

    fn read_theme_file(&self, file_name: &str) -> Option<String> {
        let relative_path = safe_relative_path(file_name)?;
        let file_path = self
            .selected_dir()
            .and_then(|dir| existing_file(dir.join(relative_path)))?;

        fs::read_to_string(file_path).ok()
    }

    fn selected_dir(&self) -> Option<&Path> {
        if self.custom_dir.join("index.html").is_file() {
            return Some(&self.custom_dir);
        }

        if self.default_dir.join("index.html").is_file() {
            return Some(&self.default_dir);
        }

        None
    }
}

fn existing_file(path: PathBuf) -> Option<PathBuf> {
    path.is_file().then_some(path)
}

fn safe_relative_path(path: &str) -> Option<PathBuf> {
    let trimmed = path.trim_start_matches('/');

    if trimmed.is_empty() {
        return None;
    }

    let candidate = Path::new(trimmed);
    if candidate.components().any(|component| {
        matches!(
            component,
            Component::ParentDir | Component::RootDir | Component::Prefix(_)
        )
    }) {
        return None;
    }

    Some(candidate.to_path_buf())
}

fn render_template(template: &str, context: &ThemeContext<'_>) -> String {
    template
        .replace("{{title}}", &html_escape(context.title))
        .replace("{{accept_url}}", &html_escape(context.accept_url))
        .replace("{{active_sessions}}", &context.active_sessions.to_string())
        .replace(
            "{{max_active_sessions}}",
            &context.max_active_sessions.to_string(),
        )
        .replace(
            "{{queue_retry_seconds}}",
            &context.queue_retry_seconds.to_string(),
        )
}

fn content_type_for(extension: Option<&str>) -> &'static str {
    match extension.unwrap_or_default() {
        "css" => "text/css; charset=utf-8",
        "gif" => "image/gif",
        "html" | "htm" => "text/html; charset=utf-8",
        "ico" => "image/x-icon",
        "jpeg" | "jpg" => "image/jpeg",
        "js" => "application/javascript; charset=utf-8",
        "json" => "application/json; charset=utf-8",
        "png" => "image/png",
        "svg" => "image/svg+xml",
        "txt" => "text/plain; charset=utf-8",
        "webp" => "image/webp",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        _ => "application/octet-stream",
    }
}

fn html_escape(s: &str) -> Cow<'_, str> {
    if !s.bytes().any(|b| matches!(b, b'&' | b'<' | b'>' | b'"')) {
        return Cow::Borrowed(s);
    }

    let mut escaped = String::with_capacity(s.len());
    for ch in s.chars() {
        match ch {
            '&' => escaped.push_str("&amp;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            '"' => escaped.push_str("&quot;"),
            _ => escaped.push(ch),
        }
    }
    Cow::Owned(escaped)
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::{Theme, ThemeContext};

    fn context() -> ThemeContext<'static> {
        ThemeContext {
            title: r#"Free<&"WiFi"#,
            accept_url: r#"/accept?x=<tag>&y="1""#,
            active_sessions: 2,
            max_active_sessions: 5,
            queue_retry_seconds: 300,
        }
    }

    #[test]
    fn renders_custom_theme_with_escaped_placeholders() {
        let base = std::env::temp_dir().join(format!("hotspot-theme-test-{}", std::process::id()));
        let custom = base.join("custom");
        let default = base.join("default");
        fs::create_dir_all(&custom).unwrap();
        fs::write(
            custom.join("index.html"),
            "{{title}} {{accept_url}} {{active_sessions}}/{{max_active_sessions}} {{queue_retry_seconds}}",
        )
        .unwrap();

        let theme = Theme::new(&custom, &default);
        let rendered = theme.render_page("index.html", &context()).unwrap();

        assert!(rendered.contains("Free&lt;&amp;&quot;WiFi"));
        assert!(rendered.contains("/accept?x=&lt;tag&gt;&amp;y=&quot;1&quot;"));
        assert!(rendered.contains("2/5 300"));

        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn falls_back_to_default_theme_when_custom_missing() {
        let base =
            std::env::temp_dir().join(format!("hotspot-default-theme-test-{}", std::process::id()));
        let custom = base.join("custom");
        let default = base.join("default");
        fs::create_dir_all(&default).unwrap();
        fs::write(default.join("index.html"), "default {{title}}").unwrap();

        let theme = Theme::new(&custom, &default);
        let rendered = theme.render_page("index.html", &context()).unwrap();

        assert!(rendered.contains("default Free&lt;&amp;&quot;WiFi"));

        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn rejects_path_traversal_assets() {
        let theme = Theme::new("/tmp/missing", "/tmp/missing");

        assert!(theme.asset("../etc/passwd").is_none());
        assert!(theme.asset("/../etc/passwd").is_none());
    }
}
