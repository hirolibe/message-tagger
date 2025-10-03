class AddTagThreadsToSlackMessageTags < ActiveRecord::Migration[8.0]
  def change
    add_column :slack_message_tags, :tag_threads, :jsonb, default: {}
  end
end
