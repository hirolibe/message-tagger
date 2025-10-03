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

    # 既存タグがあれば表示
    if existing_tags.any?
      blocks << {
        type: "section",
        text: {
          type: "mrkdwn",
          text: "*現在のタグ:* #{existing_tags.join(', ')}"
        }
      }
    end

    # 既存タグから選択（複数選択可能）
    if popular_tags.any?
      element_config = {
        type: "multi_static_select",
        action_id: "existing_tags_select",
        placeholder: { type: "plain_text", text: "既存のタグから選択" },
        options: popular_tags.map { |tag|
          {
            text: { type: "plain_text", text: tag },
            value: tag
          }
        }
      }

      # 既存タグがある場合のみ initial_options を追加
      if existing_tags.any?
        element_config[:initial_options] = existing_tags.map { |tag|
          {
            text: { type: "plain_text", text: tag },
            value: tag
          }
        }
      end

      blocks << {
        type: "input",
        block_id: "existing_tags_block",
        optional: true,
        element: element_config,
        label: { type: "plain_text", text: "既存のタグから選択（複数可）" }
      }
    end

    # 新しいタグを入力
    blocks << {
      type: "input",
      block_id: "new_tags_block",
      optional: true,
      element: {
        type: "plain_text_input",
        action_id: "new_tags_input",
        placeholder: { type: "plain_text", text: "例: bug, 重要, 確認必要" }
      },
      label: { type: "plain_text", text: "新しいタグを追加（カンマ区切り）" }
    }

    slack_client.views_open(
      trigger_id: payload["trigger_id"],
      view: {
        type: "modal",
        callback_id: "tag_modal",
        title: { type: "plain_text", text: "タグを追加" },
        submit: { type: "plain_text", text: "保存" },
        blocks: blocks,
        private_metadata: JSON.generate({
          channel_id: payload["channel"]["id"],
          message_ts: message["ts"],
          user_id: payload["user"]["id"],
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

    # 既存タグから選択されたもの
    selected_tags = []
    if values["existing_tags_block"]
      selected = values["existing_tags_block"]["existing_tags_select"]["selected_options"]
      selected_tags = selected&.map { |opt| opt["value"] } || []
    end

    # 新規タグの入力
    new_tags_input = values["new_tags_block"]["new_tags_input"]["value"]
    new_tags = new_tags_input.to_s.split(",").map(&:strip).reject(&:blank?)

    # 両方を結合
    tags = (selected_tags + new_tags).uniq

    # タグが1つも選択・入力されていない場合はエラーを返す
    if tags.empty?
      return {
        response_action: "errors",
        errors: {
          new_tags_block: "タグを1つ以上選択または入力してください"
        }
      }
    end

    # データベースに保存
    message_tag = SlackMessageTag.find_or_initialize_by(
      channel_id: metadata["channel_id"],
      message_ts: metadata["message_ts"]
    )

    message_tag.user_id = metadata["user_id"]
    message_tag.message_text = metadata["message_text"]
    message_tag.message_link = metadata["permalink"]
    message_tag.tagged_at = Time.current

    # タグを上書き（既存タグを選択し直した場合に対応）
    message_tag.tags = tags
    message_tag.save!

    # 元のメッセージに🏷️リアクションを追加
    add_reaction_to_message(metadata["channel_id"], metadata["message_ts"])

    # 元のメッセージのスレッドに返信
    reply_to_original_message(metadata, tags)

    # 各タグごとにスレッドに集約
    tags.each do |tag|
      aggregate_to_thread(tag, message_tag, metadata)
    end
  end

  def aggregate_to_thread(tag, message_tag, metadata)
    # ユーザーのDMチャンネルを取得
    dm_channel = get_or_create_dm_channel(metadata["user_id"])
    return unless dm_channel

    # ユーザーごとのタグスレッドを探す/作成
    thread_ts = find_or_create_user_tag_thread(dm_channel, tag, metadata["user_id"])
    return unless thread_ts

    # スレッドに返信を追加
    slack_client.chat_postMessage(
      channel: dm_channel,
      thread_ts: thread_ts,
      text: format_tag_message(tag, message_tag, metadata)
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
  def find_or_create_user_tag_thread(channel_id, tag, user_id)
    # このユーザーのこのタグのスレッドを探す
    existing = SlackMessageTag.where(user_id: user_id)
                              .where("tags @> ARRAY[?]::text[]", [ tag ])
                              .where.not(user_thread_ts: nil)
                              .first

    return existing.user_thread_ts if existing&.user_thread_ts

    # なければ新規作成
    response = slack_client.chat_postMessage(
      channel: channel_id,
      text: "🏷️ *#{tag}* タグのメッセージ一覧\n\nあなたがタグ付けしたメッセージが集約されます。"
    )

    thread_ts = response["ts"]

    # このユーザーのこのタグを持つメッセージに user_thread_ts を保存
    SlackMessageTag.where(user_id: user_id)
                   .where("tags @> ARRAY[?]::text[]", [ tag ])
                   .update_all(user_thread_ts: thread_ts)

    thread_ts
  rescue => e
    Rails.logger.error("Failed to create user tag thread: #{e.message}")
    nil
  end

  def format_tag_message(tag, message_tag, metadata)
    timestamp = message_tag.tagged_at.strftime("%Y-%m-%d %H:%M")
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
    response["permalink"]
  rescue
    nil
  end

  def slack_client
    @slack_client ||= Slack::Web::Client.new(token: ENV["SLACK_BOT_TOKEN"])
  end

  # 元のメッセージに🏷️リアクションを追加
  def add_reaction_to_message(channel_id, message_ts)
    slack_client.reactions_add(
      channel: channel_id,
      name: "label",  # 🏷️絵文字
      timestamp: message_ts
    )
  rescue Slack::Web::Api::Errors::AlreadyReacted
    # 既にリアクション済みの場合は無視
  rescue => e
    Rails.logger.error("Failed to add reaction: #{e.message}")
  end

  # 元のメッセージのスレッドに返信を投稿
  def reply_to_original_message(metadata, tags)
    slack_client.chat_postMessage(
      channel: metadata["channel_id"],
      thread_ts: metadata["message_ts"],
      text: "🏷️ タグを追加しました: #{tags.join(', ')}"
    )
  rescue => e
    Rails.logger.error("Failed to post thread reply: #{e.message}")
  end
end
