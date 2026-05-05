# Avatar Import (OAuth → R2)

Discourse 標準の S3 互換アップロード機構を使い、LINE / Google から取得した
アバター画像を Cloudflare R2 に格納する仕組みのセットアップ手順。

## 仕組み

```
   ┌──────────────┐    1. OAuth 完了     ┌──────────────────┐
   │   LINE /     │ ────────────────►   │  Discourse       │
   │   Google     │                     │  (Hetzner VPS)   │
   └──────────────┘                     └────────┬─────────┘
          ▲                                      │
          │ 2. avatar_url を取得                  │ 3. :after_create_account
          │    (pictureUrl / picture)             │    で Sidekiq に enqueue
          │                                       ▼
          │                              ┌──────────────────┐
          └─────────────────────────────│ Jobs::ImportOauth │
              4. HTTPS で 1 回だけ fetch  │     Avatar       │
                                         └────────┬─────────┘
                                                  │ 5. UploadCreator.new(...)
                                                  │    type: "avatar"
                                                  ▼
                                         ┌──────────────────┐
                                         │  Cloudflare R2   │
                                         │  (S3 互換 API)    │
                                         └──────────────────┘
                                                  ▲
   ┌──────────────┐    6. 以降のリクエスト           │
   │   Browser    │ ────────────────────────────────┘
   └──────────────┘    (R2 / R2 CDN から直接配信)
```

ポイント:

- フォーラムから外部 (LINE / Google CDN) への直接リクエストは
  **アバター取り込み時の 1 回だけ**。それ以降のアバター表示は R2 から行う。
- 取り込みは `:after_create_account` event hook → Sidekiq ジョブ
  `Jobs::ImportOauthAvatar` に委譲 (Web リクエストはブロックしない)。
- 取り込み失敗時は **Discourse 標準の identicon にフォールバック**。
  ユーザーのサインアップ自体は止めない (フェイルセーフ設計)。

実装本体: [`app/services/avatar_importer.rb`](../app/services/avatar_importer.rb)

## Discourse 環境変数 (`app.yml` の `env:`)

R2 へ実際に書き込むのは Discourse 側の `UploadCreator` なので、プラグイン側に
R2 SDK を追加する必要はない。Discourse の標準 S3 設定をそのまま R2 に向ける:

```yaml
env:
  DISCOURSE_USE_S3: true
  DISCOURSE_S3_REGION: auto
  DISCOURSE_S3_ENDPOINT: https://<ACCOUNT_ID>.r2.cloudflarestorage.com
  DISCOURSE_S3_ACCESS_KEY_ID: <R2_ACCESS_KEY_ID>
  DISCOURSE_S3_SECRET_ACCESS_KEY: <R2_SECRET_ACCESS_KEY>
  DISCOURSE_S3_UPLOAD_BUCKET: bayview-bbs-uploads
  DISCOURSE_S3_CDN_URL: https://uploads.bbs.kondou.com   # optional, 推奨
  DISCOURSE_S3_INSTALL_CORS_RULE: false                  # R2 は CORS を別途設定
```

| 変数 | 説明 |
|---|---|
| `DISCOURSE_USE_S3` | `true` で UploadCreator が S3 互換にプッシュするモードに切り替わる |
| `DISCOURSE_S3_REGION` | R2 はリージョン概念がないので `auto` 固定 |
| `DISCOURSE_S3_ENDPOINT` | `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` (Cloudflare ダッシュボードに表示) |
| `DISCOURSE_S3_ACCESS_KEY_ID` / `..._SECRET_ACCESS_KEY` | R2 → Manage R2 API Tokens で発行した Access Key |
| `DISCOURSE_S3_UPLOAD_BUCKET` | R2 バケット名 (例: `bayview-bbs-uploads`) |
| `DISCOURSE_S3_CDN_URL` | R2 のカスタムドメイン (Cloudflare の Custom Domain 設定後)。**未設定だと R2 の生 URL がブラウザに露出する** ので運用上ほぼ必須 |
| `DISCOURSE_S3_INSTALL_CORS_RULE` | `false` 推奨。R2 は AWS S3 と CORS API 互換性が完全ではないため、Discourse に管理させない |

機密値の保管場所は [PLAN.md §「重要ファイルパス → 機密情報」](../../multilingual-bbs/docs/PLAN.md)
を参照 (`/var/discourse/shared/secrets.env` に置いて `app.yml` から `${...}` 参照)。

## Cloudflare R2 セットアップ手順

1. **Cloudflare ダッシュボード → R2 → Create bucket**
   - Name: `bayview-bbs-uploads`
   - Location hint: `Asia-Pacific (APAC)` 推奨 (主な利用者が日本)
2. **バケット → Settings → Public access** は **無効のまま**
   (CDN URL はカスタムドメインで公開する)
3. **バケット → Settings → CORS Policy** を以下で設定 (アバター画像のブラウザ表示用):
   ```json
   [
     {
       "AllowedOrigins": ["https://forum.kondou.com"],
       "AllowedMethods": ["GET", "HEAD"],
       "AllowedHeaders": ["*"],
       "MaxAgeSeconds": 3600
     }
   ]
   ```
4. **バケット → Settings → Custom Domains → Connect Domain**
   - `uploads.bbs.kondou.com` を接続 (Cloudflare で管理しているドメイン)
   - これを `DISCOURSE_S3_CDN_URL` に設定する
5. **R2 → Manage R2 API Tokens → Create API token**
   - Permissions: **Object Read & Write**
   - Specify bucket: `bayview-bbs-uploads` のみ
   - TTL: 用途に応じて (本番運用なら無期限でも可。漏洩時はローテーション)
   - 表示された Access Key ID / Secret Access Key を `secrets.env` に保存
6. **`app.yml` を上記の env で更新 → `./launcher rebuild app`**
7. **管理画面で確認**: `/admin/site_settings/category/files` →
   - `enable s3 uploads` がオン
   - `s3 endpoint` が R2 のエンドポイントになっている
   - `Test S3 connection` (Discourse 5+ にあれば) を実行 → 成功

## 動作確認

### サインアップ後のアバター URL を確認

Google または LINE OAuth で新規ユーザーを作成 → 30 秒〜数分待つ
(Sidekiq ジョブの実行) → そのユーザーの `<img class="avatar">` の `src`
属性が以下のいずれかになっていれば OK:

- `https://uploads.bbs.kondou.com/...` (CDN URL 設定済みの場合)
- `https://<ACCOUNT_ID>.r2.cloudflarestorage.com/...` (CDN 未設定の場合)

逆に以下なら取り込み失敗:

- `https://www.gravatar.com/...` または default identicon
  → Sidekiq の `/sidekiq` ダッシュボードで `Jobs::ImportOauthAvatar` の
  失敗ログを確認
- `https://profile.line-scdn.net/...` や `https://lh3.googleusercontent.com/...`
  → R2 にコピーされていない。`auth_overrides_avatar` 設定や
  `:after_create_account` フックが発火していない可能性

### Sidekiq ログの読み方

`avatar_importer.rb` は失敗時に以下の構造化ログを Rails.logger.warn で出す:

| event | reason | 意味 |
|---|---|---|
| `avatar_import_rejected` | `insecure_scheme` | URL が https:// でない / 不正 |
| `avatar_import_rejected` | `bad_content_type` | レスポンスが image/* でない |
| `avatar_import_failed` | `fetch_error` | ネットワーク / タイムアウト / オーバーサイズ |
| `avatar_import_failed` | `upload_creator_failed` | UploadCreator が validation で reject |

`grep '\[multilingual-post\] event=avatar_import' production.log` で抽出できる。

## 関連ドキュメント

- [PLAN.md §「プロバイダ別プロビジョニング」](../../multilingual-bbs/docs/PLAN.md)
- [PLAN.md §「重要ファイルパス」](../../multilingual-bbs/docs/PLAN.md)
- Discourse 公式: <https://meta.discourse.org/t/setting-up-file-and-image-uploads-to-s3/7229>
- Cloudflare R2 + Discourse: <https://meta.discourse.org/t/using-cloudflare-r2-as-the-cdn-for-uploads/300586>
