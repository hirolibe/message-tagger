class AddUserThreadTsToSlackMessageTags < ActiveRecord::Migration[8.0]
  def change
    add_column :slack_message_tags, :user_thread_ts, :string
    add_index :slack_message_tags, [:user_id, :user_thread_ts]
  end
end
