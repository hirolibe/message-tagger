class RemoveThreadTsFromSlackMessageTags < ActiveRecord::Migration[8.0]
  def change
    remove_column :slack_message_tags, :thread_ts, :string
  end
end
