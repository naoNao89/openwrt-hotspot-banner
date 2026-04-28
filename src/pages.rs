use std::borrow::Cow;

pub const SUCCESS_PAGE: &str = r#"<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Connected!</title>
    <style>
        body { margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); min-height: 100vh;
            display: flex; align-items: center; justify-content: center; }
        .card { background: white; border-radius: 16px; padding: 40px; max-width: 420px; width: 90%;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3); text-align: center; }
        h1 { color: #333; margin: 0 0 16px 0; }
        p { color: #666; font-size: 16px; line-height: 1.5; }
        .success { font-size: 64px; margin-bottom: 16px; }
    </style>
</head>
<body>
    <div class="card">
        <div class="success">✅</div>
        <h1>You are connected!</h1>
        <p>Please close this window and continue browsing.</p>
    </div>
</body>
</html>"#;

pub const CLOSE_PAGE: &str = r#"<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Connected</title>
    <style>
        body { margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); min-height: 100vh;
            display: flex; align-items: center; justify-content: center; }
        .card { background: white; border-radius: 16px; padding: 40px; max-width: 420px; width: 90%;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3); text-align: center; }
        h1 { color: #333; margin: 0 0 16px 0; }
        p { color: #666; font-size: 16px; line-height: 1.5; }
        .success { font-size: 64px; margin-bottom: 16px; }
    </style>
</head>
<body>
    <div class="card">
        <div class="success">✅</div>
        <h1>You are connected</h1>
        <p>Tap Done to continue browsing.</p>
    </div>
</body>
</html>"#;

pub fn build_banner_page(
    title: &str,
    action_url: &str,
    tok_value: Option<&str>,
    redir_value: Option<&str>,
) -> String {
    let hidden_tok = tok_value
        .map(|v| {
            format!(
                r#"<input type="hidden" name="tok" value="{}">"#,
                html_escape(v)
            )
        })
        .unwrap_or_default();
    let hidden_redir = redir_value
        .map(|v| {
            format!(
                r#"<input type="hidden" name="redir" value="{}">"#,
                html_escape(v)
            )
        })
        .unwrap_or_default();

    format!(
        r#"<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{} - Free WiFi</title>
    <style>
        body {{
            margin: 0;
            padding: 0;
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
        }}
        .card {{
            background: white;
            border-radius: 16px;
            padding: 40px;
            max-width: 420px;
            width: 90%;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            text-align: center;
        }}
        h1 {{
            margin: 0 0 8px 0;
            font-size: 24px;
            color: #333;
        }}
        .subtitle {{
            color: #666;
            margin-bottom: 24px;
            font-size: 14px;
        }}
        .banner {{
            background: #f8f9fa;
            border-radius: 12px;
            padding: 20px;
            margin-bottom: 24px;
            border-left: 4px solid #667eea;
        }}
        .banner h2 {{
            margin: 0 0 8px 0;
            font-size: 18px;
            color: #333;
        }}
        .banner p {{
            margin: 0;
            color: #666;
            font-size: 14px;
            line-height: 1.5;
        }}
        .notice {{
            background: #fff7ed;
            border: 1px solid #fed7aa;
            border-radius: 12px;
            padding: 14px;
            margin-bottom: 20px;
            color: #9a3412;
            font-size: 14px;
            line-height: 1.45;
        }}
        button {{
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            border: none;
            padding: 14px 32px;
            border-radius: 8px;
            font-size: 16px;
            font-weight: 600;
            cursor: pointer;
            width: 100%;
            transition: transform 0.2s, box-shadow 0.2s;
        }}
        button:hover {{
            transform: translateY(-2px);
            box-shadow: 0 8px 20px rgba(102, 126, 234, 0.4);
        }}
        .terms {{
            margin-top: 16px;
            font-size: 12px;
            color: #999;
        }}
        .terms a {{
            color: #667eea;
            text-decoration: none;
        }}
        .wifi-icon {{
            font-size: 64px;
            margin-bottom: 16px;
        }}
    </style>
</head>
<body>
    <div class="card">
        <div class="wifi-icon">📶</div>
        <h1>{}</h1>
        <p class="subtitle">One tap required to start internet</p>
        <div class="banner">
            <h2>Welcome to FreeWiFi</h2>
            <p>Please view this message, then tap the button below to unlock free internet access.</p>
        </div>
        <div class="notice">
            Closing this page will keep WiFi connected, but internet will stay paused until you tap Connect.
        </div>
        <form method="GET" action="{}">
            {}
            {}
            <button type="submit">Connect & Start Internet</button>
        </form>
        <p class="terms">
            By connecting, you agree to our Terms of Service.<br>
            Your connection is isolated for security.
        </p>
    </div>
</body>
</html>"#,
        html_escape(title),
        html_escape(title),
        html_escape(action_url),
        hidden_tok,
        hidden_redir,
    )
}

pub fn build_queue_page(retry_seconds: u64, active_sessions: usize, max_sessions: usize) -> String {
    let retry_minutes = retry_seconds.div_ceil(60);

    format!(
        r#"<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="refresh" content="{}">
    <title>FreeWiFi Queue</title>
    <style>
        body {{
            margin: 0;
            padding: 0;
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
        }}
        .card {{
            background: white;
            border-radius: 16px;
            padding: 40px;
            max-width: 420px;
            width: 90%;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            text-align: center;
        }}
        h1 {{
            margin: 0 0 8px 0;
            font-size: 24px;
            color: #333;
        }}
        p {{
            color: #666;
            font-size: 15px;
            line-height: 1.5;
        }}
        .queue-icon {{
            font-size: 64px;
            margin-bottom: 16px;
        }}
        .notice {{
            background: #fff7ed;
            border: 1px solid #fed7aa;
            border-radius: 12px;
            padding: 14px;
            margin: 20px 0;
            color: #9a3412;
            font-size: 14px;
            line-height: 1.45;
        }}
        .meta {{
            color: #999;
            font-size: 12px;
        }}
    </style>
</head>
<body>
    <div class="card">
        <div class="queue-icon">⏳</div>
        <h1>FreeWiFi is full</h1>
        <p>Too many guests are online right now. Please stay connected to WiFi and try again soon.</p>
        <div class="notice">Estimated wait: about {} minute(s). This page will refresh automatically.</div>
        <p class="meta">Active sessions: {} / {}</p>
    </div>
</body>
</html>"#,
        retry_seconds, retry_minutes, active_sessions, max_sessions,
    )
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
    use super::{build_banner_page, build_queue_page};

    #[test]
    fn queue_page_contains_retry_and_capacity_details() {
        let page = build_queue_page(300, 30, 30);

        assert!(page.contains("FreeWiFi is full"));
        assert!(page.contains(r#"<meta http-equiv="refresh" content="300">"#));
        assert!(page.contains("Estimated wait: about 5 minute(s)"));
        assert!(page.contains("Active sessions: 30 / 30"));
    }

    #[test]
    fn queue_page_rounds_retry_seconds_up_to_minutes() {
        let page = build_queue_page(301, 29, 30);

        assert!(page.contains(r#"<meta http-equiv="refresh" content="301">"#));
        assert!(page.contains("Estimated wait: about 6 minute(s)"));
        assert!(page.contains("Active sessions: 29 / 30"));
    }

    #[test]
    fn banner_page_escapes_dynamic_values() {
        let page = build_banner_page(
            r#"Free<&"WiFi"#,
            r#"/accept?x=<tag>&y="1""#,
            Some(r#"tok<&""#),
            Some(r#"redir<&""#),
        );

        assert!(page.contains("Free&lt;&amp;&quot;WiFi"));
        assert!(page.contains("/accept?x=&lt;tag&gt;&amp;y=&quot;1&quot;"));
        assert!(page.contains("tok&lt;&amp;&quot;"));
        assert!(page.contains("redir&lt;&amp;&quot;"));
    }
}
