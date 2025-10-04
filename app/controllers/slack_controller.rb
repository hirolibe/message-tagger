class SlackController < ApplicationController
  skip_before_action :verify_authenticity_token

  def interactions
    payload = JSON.parse(params[:payload])

    case payload["type"]
    when "message_action", "shortcut"
      handle_shortcut(payload)
      head :ok
    when "view_submission"
      handle_tag_submission(payload)
      # モーダルを閉じるために空のレスポンスを返す
      render json: {}, status: :ok
    else
      head :ok
    end
  end

  private

  def handle_shortcut(payload)
    return unless payload["callback_id"] == "add_message_tag"

    open_tag_modal(payload)
  end

  def open_tag_modal(payload)
    message = payload["message"]

    # 既存のメッセージにタグが付いているか確認
    existing_tag = SlackMessageTag.find_by(
      channel_id: payload["channel"]["id"],
      message_ts: message["ts"]
    )
    existing_tags = existing_tag&.tags || []

    # よく使われているタグを取得（頻度順、上位20件）
    popular_tags = SlackMessageTag.pluck(:tags)
                                  .flatten
                                  .group_by(&:itself)
                                  .transform_values(&:count)
                                  .sort_by { |_, count| -count }
                                  .first(20)
                                  .map(&:first)

    blocks = []

    # 既存タグから選択（単一選択）
    if popular_tags.any?
      blocks << {
        type: "input",
        block_id: "existing_tag_block",
        optional: true,
        element: {
          type: "static_select",
          action_id: "existing_tag_select",
          placeholder: { type: "plain_text", text: "既存のタグから選択" },
          options: popular_tags.map { |tag|
            {
              text: { type: "plain_text", text: tag },
              value: tag
            }
          }
        },
        label: { type: "plain_text", text: "既存のタグから選択" }
      }
    end

    # または、新しいタグを入力
    blocks << {
      type: "input",
      block_id: "new_tag_block",
      optional: true,
      element: {
        type: "plain_text_input",
        action_id: "new_tag_input",
        placeholder: { type: "plain_text", text: "例: Rails" }
      },
      label: { type: "plain_text", text: "または、新しいタグを入力" }
    }

    # メッセージ投稿者の情報を取得
    message_user_info = get_user_info(message["user"])
    
    slack_client.views_open(
      trigger_id: payload["trigger_id"],
      view: {
        type: "modal",
        callback_id: "tag_modal",
        title: { type: "plain_text", text: "タグをつける" },
        submit: { type: "plain_text", text: "保存" },
        blocks: blocks,
        private_metadata: JSON.generate({
          channel_id: payload["channel"]["id"],
          message_ts: message["ts"],
          user_id: payload["user"]["id"],
          message_user_id: message["user"],
          message_user_name: message_user_info&.dig("user", "real_name") || message_user_info&.dig("user", "name") || "Unknown",
          message_text: message["text"],
          permalink: message_permalink(payload["channel"]["id"], message["ts"])
        })
      }
    )
  end

  def handle_tag_submission(payload)
    return unless payload["view"]["callback_id"] == "tag_modal"

    metadata = JSON.parse(payload["view"]["private_metadata"])
    values = payload["view"]["state"]["values"]

    # 新規タグの入力
    new_tag_input = values["new_tag_block"]["new_tag_input"]["value"]
    new_tag = new_tag_input.to_s.strip

    # 既存タグから選択されたもの
    selected_tag = nil
    if values["existing_tag_block"]
      selected = values["existing_tag_block"]["existing_tag_select"]["selected_option"]
      selected_tag = selected["value"] if selected
    end

    # 新規タグが入力されていれば、それを優先（既存選択は無視）
    # そうでなければ既存選択を使用
    tag = new_tag.present? ? new_tag : selected_tag

    # タグが選択・入力されていない場合はエラーを返す
    if tag.blank?
      return {
        response_action: "errors",
        errors: {
          new_tag_block: "タグを選択または入力してください"
        }
      }
    end

    # 配列形式に変換（既存のロジックとの互換性のため）
    tags = [ tag ]

    # データベースに保存
    message_tag = SlackMessageTag.find_or_initialize_by(
      channel_id: metadata["channel_id"],
      message_ts: metadata["message_ts"]
    )

    message_tag.user_id = metadata["user_id"]
    message_tag.message_text = metadata["message_text"]
    message_tag.message_link = metadata["permalink"]
    message_tag.tagged_at = Time.current

    # タグを追加（既存のタグに新しいタグを追加）
    message_tag.tags = (message_tag.tags + tags).uniq
    message_tag.save!

    # 非同期で処理を実行（Slackへの通信が遅い場合のため）
    Thread.new do
      # 元のメッセージのスレッドに返信
      reply_to_original_message(metadata, tags)

      # 各タグごとにスレッドに集約
      tags.each do |tag|
        aggregate_to_thread(tag, message_tag, metadata)
      end
    end

    # 何も返さない（モーダルを閉じる）
    nil
  end

  def aggregate_to_thread(tag, message_tag, metadata)
    # ユーザーのDMチャンネルを取得
    dm_channel = get_or_create_dm_channel(metadata["user_id"])
    return unless dm_channel

    # ユーザーごとのタグスレッドを探す/作成（message_tagを渡す）
    thread_ts = find_or_create_user_tag_thread(dm_channel, tag, metadata["user_id"], message_tag)
    return unless thread_ts

    # スレッドに返信を追加
    slack_client.chat_postMessage(
      channel: dm_channel,
      thread_ts: thread_ts,
      text: format_tag_message(tag, message_tag, metadata),
      unfurl_links: false
    )
  end

  # ユーザーのDMチャンネルを取得または作成
  def get_or_create_dm_channel(user_id)
    response = slack_client.conversations_open(users: user_id)
    response["channel"]["id"]
  rescue => e
    Rails.logger.error("Failed to open DM channel: #{e.message}")
    nil
  end

  # ユーザーごとのタグスレッドを探すか作成
  def find_or_create_user_tag_thread(channel_id, tag, user_id, message_tag)
    # このメッセージのこのタグのスレッドを探す（tag_threadsから）
    if message_tag.tag_threads && message_tag.tag_threads[tag]
      return message_tag.tag_threads[tag]
    end

    # なければ新規作成
    response = slack_client.chat_postMessage(
      channel: channel_id,
      text: "🏷️ *#{tag}*"
    )

    thread_ts = response["ts"]

    # このタグのスレッドIDを保存
    message_tag.tag_threads ||= {}
    message_tag.tag_threads[tag] = thread_ts
    message_tag.save!

    thread_ts
  rescue => e
    Rails.logger.error("Failed to create user tag thread: #{e.message}")
    nil
  end

  def format_tag_message(tag, message_tag, metadata)
    user_name = metadata['message_user_name'] || "Unknown"
    <<~TEXT
      <#{metadata['permalink']}|@#{user_name} さんのメッセージ>
    TEXT
  end

  def message_permalink(channel_id, message_ts)
    response = slack_client.chat_getPermalink(
      channel: channel_id,
      message_ts: message_ts
    )
    response["permalink"]
  rescue
    nil
  end

  def get_user_info(user_id)
    slack_client.users_info(user: user_id)
  rescue
    nil
  end

  def slack_client
    @slack_client ||= Slack::Web::Client.new(token: ENV["SLACK_BOT_TOKEN"])
  end

  # 元のメッセージのスレッドに返信を投稿
  def reply_to_original_message(metadata, tags)
    slack_client.chat_postMessage(
      channel: metadata["channel_id"],
      thread_ts: metadata["message_ts"],
      text: "<@#{metadata['user_id']}> さんが `#{tags.first}` 🏷️ タグをつけました"
    )
  rescue => e
    Rails.logger.error("Failed to post thread reply: #{e.message}")
  end
end
