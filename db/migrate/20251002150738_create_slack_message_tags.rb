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
