# MessageTagger - Slackタグ付けアプリ開発プロンプト

## プロジェクト概要
Slackのメッセージにタグを付けて整理・検索できるRailsアプリケーションを開発します。
タグ付けされたメッセージは自動的に専用チャンネルのスレッドに集約され、Slack AIで要約可能になります。

## 技術スタック
- Ruby on Rails 8
- PostgreSQL
- Slack API (slack-ruby-client gem)
- TailwindCSS
- ローカル開発環境

## 不要なもの
- Kamal（デプロイツール）
- Solid Queue / Solid Cable
- 認証システム（今のところ）
- テストフレームワーク（--skip-test）

---

## セットアップ手順

### 1. プロジェクト作成
```bash
rails new message_tagger \
  --database=postgresql \
  --skip-test \
  --css=tailwind \
  --skip-solid \
  --skip-kamal

cd message_tagger

# Claude Code初期化
claude init
```

### 2. Gemfile追加
`Gemfile`に以下を追記：

```ruby
# Slack API client
gem 'slack-ruby-client'

# 環境変数管理
gem 'dotenv-rails', groups: [:development, :test]

# デバッグ用
group :development do
  gem 'pry-rails'
end
```

その後：
```bash
bundle install
```

### 3. 環境変数ファイル作成
`.env`ファイルをプロジェクトルートに作成：

```bash
# Slack Bot Token (xoxb-で始まる)
SLACK_BOT_TOKEN=xoxb-your-bot-token-here

# Slack Signing Secret
SLACK_SIGNING_SECRET=your-signing-secret-here

# タグ集約用チャンネルID（#tag-summaryのチャンネルID）
SLACK_SUMMARY_CHANNEL_ID=C1234567890

# Database
DATABASE_URL=postgresql://localhost/message_tagger_development
```

`.gitignore`に`.env`が含まれていることを確認してください。

---

## データベース設計

### SlackMessageTagモデルを作成

```bash
rails generate model SlackMessageTag channel_id:string message_ts:string user_id:string tags:text tagged_at:datetime
```

生成されたマイグレーションファイル（`db/migrate/XXXXXX_create_slack_message_tags.rb`）を以下のように編集：

```ruby
class CreateSlackMessageTags < ActiveRecord::Migration[8.0]
  def change
    create_table :slack_message_tags do |t|
      t.string :channel_id, null: false
      t.string :message_ts, null: false  # Slackのタイムスタンプ
      t.string :user_id, null: false     # タグを付けたユーザー
      t.text :tags, array: true, default: []  # タグの配列
      t.text :message_text  # メッセージ本文（検索用）
      t.string :message_link  # Slackメッセージへのリンク
      t.string :thread_ts  # 集約スレッドのタイムスタンプ
      t.datetime :tagged_at

      t.timestamps
    end

    add_index :slack_message_tags, [:channel_id, :message_ts], unique: true
    add_index :slack_message_tags, :tags, using: :gin
    add_index :slack_message_tags, :tagged_at
  end
end
```

マイグレーション実行：
```bash
rails db:create
rails db:migrate
```

---

## モデル実装

### app/models/slack_message_tag.rb

```ruby
class SlackMessageTag < ApplicationRecord
  validates :channel_id, presence: true
  validates :message_ts, presence: true
  validates :user_id, presence: true
  validates :tags, presence: true

  # タグで検索
  scope :with_tag, ->(tag) { where("? = ANY(tags)", tag) }
  scope :with_any_tags, ->(tags) { where("tags && ARRAY[?]::text[]", tags) }
  scope :recent, -> { order(tagged_at: :desc) }

  # タグを追加（重複を防ぐ）
  def add_tags(new_tags)
    self.tags = (tags + new_tags).uniq
    save
  end
end
```

---

## コントローラー実装

### app/controllers/slack_controller.rb

新規ファイルを作成：

```ruby
class SlackController < ApplicationController
  skip_before_action :verify_authenticity_token

  def interactions
    payload = JSON.parse(params[:payload])

    case payload['type']
    when 'shortcut'
      handle_shortcut(payload)
    when 'view_submission'
      handle_tag_submission(payload)
    end

    head :ok
  end

  private

  def handle_shortcut(payload)
    return unless payload['callback_id'] == 'add_message_tag'

    open_tag_modal(payload)
  end

  def open_tag_modal(payload)
    message = payload['message']
    
    slack_client.views_open(
      trigger_id: payload['trigger_id'],
      view: {
        type: 'modal',
        callback_id: 'tag_modal',
        title: { type: 'plain_text', text: 'タグを追加' },
        submit: { type: 'plain_text', text: '追加' },
        blocks: [
          {
            type: 'input',
            block_id: 'tags_block',
            element: {
              type: 'plain_text_input',
              action_id: 'tags_input',
              placeholder: { type: 'plain_text', text: '例: bug, 重要, 確認必要' }
            },
            label: { type: 'plain_text', text: 'タグ（カンマ区切り）' }
          }
        ],
        private_metadata: JSON.generate({
          channel_id: payload['channel']['id'],
          message_ts: message['ts'],
          user_id: payload['user']['id'],
          message_text: message['text'],
          permalink: message_permalink(payload['channel']['id'], message['ts'])
        })
      }
    )
  end

  def handle_tag_submission(payload)
    return unless payload['view']['callback_id'] == 'tag_modal'

    metadata = JSON.parse(payload['view']['private_metadata'])
    tags_input = payload['view']['state']['values']['tags_block']['tags_input']['value']
    tags = tags_input.split(',').map(&:strip).reject(&:blank?)

    # データベースに保存
    message_tag = SlackMessageTag.find_or_initialize_by(
      channel_id: metadata['channel_id'],
      message_ts: metadata['message_ts']
    )
    
    message_tag.user_id = metadata['user_id']
    message_tag.message_text = metadata['message_text']
    message_tag.message_link = metadata['permalink']
    message_tag.tagged_at = Time.current
    message_tag.add_tags(tags)

    # 各タグごとにスレッドに集約
    tags.each do |tag|
      aggregate_to_thread(tag, message_tag, metadata)
    end
  end

  def aggregate_to_thread(tag, message_tag, metadata)
    summary_channel = ENV['SLACK_SUMMARY_CHANNEL_ID'] # #tag-summary のチャンネルID
    
    # 既存のタグスレッドを探す
    thread_ts = find_or_create_tag_thread(summary_channel, tag)
    
    # スレッドに返信を追加
    slack_client.chat_postMessage(
      channel: summary_channel,
      thread_ts: thread_ts,
      text: format_tag_message(tag, message_tag, metadata)
    )
  end

  def find_or_create_tag_thread(channel_id, tag)
    # まず既存のスレッドを探す（データベースから）
    existing = SlackMessageTag.where("tags @> ARRAY[?]::text[]", [tag])
                              .where.not(thread_ts: nil)
                              .first

    return existing.thread_ts if existing&.thread_ts

    # なければ新規作成
    response = slack_client.chat_postMessage(
      channel: channel_id,
      text: "🏷️ *#{tag}* タグのメッセージ一覧\n\nこのスレッドに「#{tag}」タグが付けられたメッセージが集約されます。"
    )

    # thread_tsを保存
    thread_ts = response['ts']
    
    # このタグを持つ全てのメッセージに thread_ts を保存
    SlackMessageTag.where("tags @> ARRAY[?]::text[]", [tag]).update_all(thread_ts: thread_ts)
    
    thread_ts
  end

  def format_tag_message(tag, message_tag, metadata)
    timestamp = message_tag.tagged_at.strftime('%Y-%m-%d %H:%M')
    user_mention = "<@#{metadata['user_id']}>"
    
    <<~TEXT
      [#{timestamp}] #{user_mention}
      #{metadata['message_text'].truncate(200)}
      → <#{metadata['permalink']}|元のメッセージを見る>
    TEXT
  end

  def message_permalink(channel_id, message_ts)
    response = slack_client.chat_getPermalink(
      channel: channel_id,
      message_ts: message_ts
    )
    response['permalink']
  rescue
    nil
  end

  def slack_client
    @slack_client ||= Slack::Web::Client.new(token: ENV['SLACK_BOT_TOKEN'])
  end
end
```

---

## ルーティング設定

### config/routes.rb

既存のルートに以下を追加：

```ruby
Rails.application.routes.draw do
  # Slack interactions endpoint
  post '/slack/interactions', to: 'slack#interactions'
  
  # Health check
  get "up" => "rails/health#show", as: :rails_health_check
end
```

---

## Slack App設定

### 1. 基本情報
- **App名**: MessageTagger または TagBot
- **簡単な説明**: Slackメッセージに簡単にタグを付けて整理・管理できるボット
- **長い説明**:
  ```
  MessageTaggerは、Slackのメッセージに簡単にタグを付けて整理できるアプリです。
  
  メッセージの「...」メニューから「タグを追加」を選ぶだけで、任意のタグを付けることができます。重要なメッセージ、タスク、バグ報告など、あらゆる情報を分類して管理できます。
  
  【主な機能】
  ・メッセージへのタグ付け
  ・カンマ区切りで複数タグの追加
  ・チーム全体での情報共有と分類
  
  膨大なメッセージの中から必要な情報を素早く見つけたい、チームで情報を整理したい、そんなニーズに応えます。シンプルな操作で、Slackでの情報管理をより効率的にします。
  ```
- **アイコン**: 2000x2000px、1.5MB未満のPNG画像

### 2. OAuth Scopes（ボットトークンスコープ）
以下のスコープを追加：
```
chat:write
channels:history
groups:history
im:history (オプション)
mpim:history (オプション)
```

### 3. Interactivity & Shortcuts
- **Interactivity**: ON
- **Request URL**: `https://your-ngrok-url.ngrok.io/slack/interactions`
- **Message Shortcut**を作成:
  - Type: On messages
  - Name: タグを追加
  - Short Description: メッセージにタグを付けます
  - Callback ID: `add_message_tag`

### 4. Install App
- 「Install to Workspace」をクリック
- 個人用としてインストール（開発・テスト用）

### 5. トークン取得
- **OAuth & Permissions** → Bot User OAuth Token をコピー
- **Basic Information** → Signing Secret をコピー
- `.env`ファイルに設定

---

## 開発フロー

### 1. 開発サーバー起動
```bash
rails server
```

### 2. ngrokでトンネル作成
別のターミナルで：
```bash
ngrok http 3000
```

ngrokが生成したURLをメモ（例: `https://abc123.ngrok.io`）

### 3. Slack AppにURL設定
Slack Appの「Interactivity & Shortcuts」画面で:
```
Request URL: https://abc123.ngrok.io/slack/interactions
```

### 4. #tag-summaryチャンネルを作成
Slackワークスペースに `#tag-summary` チャンネルを作成し、チャンネルIDを取得して`.env`に設定

チャンネルIDの取得方法：
- チャンネルを右クリック → 「リンクをコピー」
- URLの最後の部分がチャンネルID（例: C1234567890）

---

## 動作フロー

### タグ付けフロー
1. ユーザーがSlackメッセージの「...」（その他のアクション）メニューから「タグを追加」を選択
2. モーダルが開き、タグを入力（カンマ区切りで複数可：`bug, 重要, 確認必要`）
3. 「追加」ボタンをクリックすると:
   - データベースにタグ情報を保存
   - `#tag-summary` チャンネルで該当タグのスレッドを探す
   - スレッドがなければ親メッセージを作成: "🏷️ {tag} タグのメッセージ一覧"
   - スレッドに返信として元メッセージ情報を投稿:
     ```
     [2025-10-02 14:30] @username
     メッセージテキスト（最大200文字）
     → 元のメッセージを見る
     ```

### スレッド集約の仕組み
- タグごとに1つの親メッセージを作成
- 同じタグが付けられたメッセージは全て同じスレッドに集約される
- ユーザーはスレッド全体に対してSlack AIの「要約」機能を使える

---

## 今後の拡張機能（オプション）

### 1. スラッシュコマンドでの検索機能
```
/tag-search bug
→ 「bug」タグが付いたメッセージを検索して表示
```

実装時には:
- Slack Appの「Slash Commands」を有効化
- コマンド名: `/tag-search`
- Request URL: `https://your-app.com/slack/commands`
- 新しいコントローラーアクション追加
- データベースクエリで検索実行

### 2. Claude APIによる要約機能
```
/tag-search bug --summary
→ 検索結果をClaude APIで要約
```

実装時には:
- `anthropic` gem を追加
- Claude APIキーを環境変数に設定
- 検索結果をプロンプトとしてClaude APIに送信

---

## デバッグ・トラブルシューティング

### ログ出力
`slack_controller.rb`の`interactions`メソッドに追加：
```ruby
def interactions
  payload = JSON.parse(params[:payload])
  Rails.logger.info "=== Slack Payload ==="
  Rails.logger.info payload.inspect
  # ... 以降の処理
end
```

### ngrokの確認
ブラウザで `http://127.0.0.1:4040` を開くと、ngrokが受信したリクエストを確認できます

### Slackからのリクエストが届かない場合
1. ngrokが起動しているか確認
2. Slack AppのRequest URLが正しいか確認
3. Railsサーバーが起動しているか確認
4. ルーティングが正しいか確認: `rails routes | grep slack`

### データベースエラー
```bash
rails db:reset  # データベースをリセット
rails db:migrate  # マイグレーションを再実行
```

---

## 注意事項

1. **CSRF対策**: Slack webhookは `skip_before_action :verify_authenticity_token` が必要
2. **セキュリティ**: 本番環境では Slack Signing Secretで署名検証を実装すべき
3. **Rate Limit**: Slack API呼び出しには制限があるため、将来的にはジョブキュー（Solid Queue等）の導入を検討
4. **エラーハンドリング**: Slack API呼び出し失敗時の処理を実装推奨
5. **環境変数管理**: `.env`ファイルは`.gitignore`に含める（誤ってコミットしない）

---

## プロジェクトの目標
個人用として開発・テストし、動作確認後にチームに展開する

---

## 参考リンク
- Slack API Documentation: https://api.slack.com/
- slack-ruby-client: https://github.com/slack-ruby/slack-ruby-client
- Rails Guides: https://guides.rubyonrails.org/
