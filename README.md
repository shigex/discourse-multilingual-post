# discourse-multilingual-post

Per-post and per-profile translation cached by user-preferred locale, served from a self-hosted local LLM.

Built originally for [Bayview Multilingual BBS](https://github.com/shigex/multilingal-bbs) — a 250-resident share-house forum where 80% of residents are non-Japanese speakers.

## What it does

- **Pre-cache** every new post into 7 priority locales (Tier 1) at write time, so all readers see content in their preferred language without waiting.
- **Toggle** between original and translation by clicking the post body.
- **Source-language badge** uses native-script labels (e.g. `JA 日本語`, `ZH-TW 繁體中文`) instead of country flags — flags don't map to languages cleanly (Spanish, English, Chinese, French are spoken across many countries).
- **Lazy translate** Tier 2 locales on first viewer access.
- **Async + resilient**: if the LLM is offline, posts still display in the original language. Sidekiq retries with exponential backoff and fills in translations when the LLM recovers.
- **Profile-aware**: user bios, hobbies, stay-period notes also get translated.
- **Soft nudge** for users who haven't filled in their profile (banner is dismissable, not blocking).
- **Multisite-friendly**: each site keeps its own `post_translations` table.

## Architecture

```
Discourse (any host) ──┐
                       │ HTTPS
                       ▼
            Cloudflare Tunnel + Access (service token)
                       │
                       ▼
            Local LLM server on a Mac/PC (vllm-mlx, Ollama, etc.)
            Any OpenAI-compatible /v1/chat/completions endpoint works.
```

The plugin doesn't care which model you run as long as the endpoint:
- speaks OpenAI-compatible chat completions
- accepts `response_format: {type: "json_object"}` (used to force structured output)

Tested with **TranslateGemma 12B Q4** (MLX). Should also work with Gemma 4 26B-A4B, Qwen 3.6 35B-A3B, etc.

## Tier 1 / Tier 2 locales

Pre-cache (Tier 1):

| Locale | Native label |
|---|---|
| `ja` | 日本語 |
| `en` | English |
| `ko` | 한국어 |
| `de` | Deutsch |
| `es` | Español |
| `zh-CN` | 中文 (简体) |
| `zh-TW` | 中文 (繁體) |
| `fr` | Français |

Lazy / on-demand (Tier 2):

`pt`, `it`, `ru`, `bn`, `vi`, `id`, `pl`

Edit `MultilingualPost::TIER1_LOCALES` / `TIER2_LOCALES` in `plugin.rb` to fit your community.

## Installation

In your `app.yml`:

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone --depth=1 https://github.com/shigex/discourse-multilingual-post.git

env:
  TRANSLATION_LLM_BASE_URL: "https://your-llm.example.com/v1"
  TRANSLATION_LLM_MODEL: "translategemma-12b-q4"
  TRANSLATION_LLM_CF_ACCESS_CLIENT_ID: "<from secrets>"
  TRANSLATION_LLM_CF_ACCESS_CLIENT_SECRET: "<from secrets>"
```

Then:

```bash
cd /var/discourse
./launcher rebuild app
```

## Site Settings

| Setting | Default | Purpose |
|---|---|---|
| `multilingual_post_enabled` | `true` | Master switch |
| `multilingual_post_show_origin_badge` | `true` | Show the source-language pill on each post |
| `multilingual_post_force_language_selection_on_first_login` | `true` | Block the main page until the user picks a display language |
| `multilingual_post_empty_profile_banner_dismiss_days` | `7` | Days the empty-bio banner stays hidden after dismissal |
| `multilingual_post_translation_request_timeout_seconds` | `60` | Per-request timeout against the LLM |

## Tests

```bash
./launcher enter app
cd /var/www/discourse
bundle exec rspec plugins/discourse-multilingual-post/spec
```

## License

GPL v2. Compatible with Discourse core licensing.
