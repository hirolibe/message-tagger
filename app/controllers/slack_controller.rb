class SlackController < ApplicationController
  skip_before_action :verify_authenticity_token

  def interactions
    payload = JSON.parse(params[:payload])

    case payload['type']
    when 'message_action', 'shortcut'
      handle_shortcut(payload)
      head :ok
    when 'view_submission'
      handle_tag_submission(payload)
      # モーダルを閉じるために空のレスポンスを返す
      render json: {}, status: :ok
    else
      head :ok
    end
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

    # 元のメッセージに🏷️リアクションを追加
    add_reaction_to_message(metadata['channel_id'], metadata['message_ts'])

    # 元のメッセージのスレッドに返信
    reply_to_original_message(metadata, tags)

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

  # 元のメッセージに🏷️リアクションを追加
  def add_reaction_to_message(channel_id, message_ts)
    slack_client.reactions_add(
      channel: channel_id,
      name: 'label',  # 🏷️絵文字
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
      channel: metadata['channel_id'],
      thread_ts: metadata['message_ts'],
      text: "🏷️ タグを追加しました: #{tags.join(', ')}"
    )
  rescue => e
    Rails.logger.error("Failed to post thread reply: #{e.message}")
  end
end
