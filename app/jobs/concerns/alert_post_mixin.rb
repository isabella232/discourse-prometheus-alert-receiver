# frozen_string_literal: true

module AlertPostMixin
  extend ActiveSupport::Concern

  FIRING_TAG = "firing".freeze
  HIGH_PRIORITY_TAG = "high-priority".freeze
  NEXT_BUSINESS_DAY_SLA = "nbd".freeze

  MAX_BUMP_RATE = 5.minutes

  PREVIOUS_TOPIC = DiscoursePrometheusAlertReceiver::PREVIOUS_TOPIC_CUSTOM_FIELD
  TOPIC_BODY = DiscoursePrometheusAlertReceiver::TOPIC_BODY_CUSTOM_FIELD
  BASE_TITLE = DiscoursePrometheusAlertReceiver::TOPIC_BASE_TITLE_CUSTOM_FIELD

  private

  def parse_alerts(raw_alerts, external_url:, logs_url: nil, grafana_url: nil)
    raw_alerts.map do |raw_alert|
      alert = {
        external_url: external_url,
        alertname: raw_alert['labels']['alertname'],
        datacenter: raw_alert["labels"]["datacenter"],
        identifier: raw_alert['labels']['id'] || '',
        status: normalize_status(raw_alert['status']),
        starts_at: raw_alert['startsAt'],
        ends_at: raw_alert['status'] == 'firing' ? nil : raw_alert['endsAt'],
        graph_url: raw_alert['generatorURL'],
        description: raw_alert.dig('annotations', 'description'),
        logs_url: logs_url
      }

      if dashboard_path = raw_alert.dig('annotations', 'grafana_dashboard_path')
        alert[:grafana_url] = "#{grafana_url}#{dashboard_path}"
      end

      alert[:ends_at] = nil if alert[:status] != 'resolved'

      alert
    end
  end

  def normalize_status(status)
    status = status['state'] if status.is_a?(Hash)
    return "firing" if status == "active"
    status
  end

  def local_date(time)
    parsed = Time.zone.parse(time)

    <<~DATE.chomp
      [date=#{parsed.strftime("%Y-%m-%d")} time=#{parsed.strftime("%H:%M:%S")} format="YYYY-MM-DD HH:mm" displayedTimezone="UTC"]
    DATE
  end

  def prev_topic_link(topic_id)
    return "" if topic_id.nil?
    return "" unless created_at = Topic.where(id: topic_id).pluck_first(:created_at)
    "[Previous alert](#{Discourse.base_url}/t/#{topic_id}) #{local_date(created_at.to_s)}\n\n"
  end

  def generate_title(base_title, firing_count)
    base_title = base_title.presence || I18n.t('prom_alert_receiver.topic_title.untitled')
    if firing_count > 0
      I18n.t("prom_alert_receiver.topic_title.firing", base_title: base_title, count: firing_count)
    else
      I18n.t("prom_alert_receiver.topic_title.not_firing", base_title: base_title)
    end
  end

  def first_post_body(topic_body: "", prev_topic_id:)
    output = "#{topic_body}"
    output += "\n\n#{prev_topic_link(prev_topic_id)}" if prev_topic_id
    output
  end

  def revise_topic(topic:, high_priority: false)
    firing_count = topic.alert_receiver_alerts.firing.count
    firing = firing_count > 0

    title = generate_title(
      topic.custom_fields[BASE_TITLE],
      firing_count
    )

    raw = first_post_body(
      topic_body: topic.custom_fields[TOPIC_BODY],
      prev_topic_id: topic.custom_fields[PREVIOUS_TOPIC]
    )

    datacenters = topic.alert_receiver_alerts.distinct.pluck(:datacenter).compact

    existing_tags = topic.tags.pluck(:name)
    new_tags = existing_tags

    new_tags.concat(datacenters)
    new_tags << HIGH_PRIORITY_TAG.dup if high_priority

    if firing
      new_tags << FIRING_TAG.dup
    else
      new_tags.delete(FIRING_TAG)
    end

    tags_changed = new_tags.uniq != existing_tags
    title_changed = topic.title != title
    raw_changed = topic.first_post.raw != raw

    if raw_changed || title_changed || tags_changed
      PostRevisor.new(topic.first_post, topic).revise!(
        Discourse.system_user,
        {
          title: title,
          raw: raw,
          tags: new_tags
        },
        skip_revision: true,
        skip_validations: true,
        validate_topic: true # This is a very weird API
      )

      if firing && title_changed && topic.bumped_at < MAX_BUMP_RATE.ago
        # Articifically bump the topic
        topic.update_column(:bumped_at, Time.now)
        TopicTrackingState.publish_latest(topic)
      end
    else
      # The topic hasn't changed
      # The alert data has changed, so notify clients to reload
      topic.first_post.publish_change_to_clients(:revised, reload_topic: true)
    end
  end

  def publish_alert_counts
    MessageBus.publish("/alert-receiver",
      firing_alerts_count: Topic.firing_alerts.count,
      open_alerts_count: Topic.open_alerts.count
    )
  end
end
