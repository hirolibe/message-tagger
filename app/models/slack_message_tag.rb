class SlackMessageTag < ApplicationRecord
  validates :channel_id, presence: true
  validates :message_ts, presence: true
  validates :user_id, presence: true
  validates :tags, presence: true
end
