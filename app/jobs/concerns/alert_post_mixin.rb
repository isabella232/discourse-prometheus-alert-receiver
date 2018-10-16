module AlertPostMixin
  extend ActiveSupport::Concern

  FIRING_TAG = "firing".freeze
  HIGH_PRIORITY_TAG = "high-priority".freeze

  private

  def render_alerts(alert_history)
    firing_alerts = []
    resolved_alerts = []
    silenced_alerts = []
    stale_alerts = []

    alert_history.each do |alert|
      status = alert['status']

      case
      when is_firing?(status)
        firing_alerts << alert
      when status == 'resolved'
        resolved_alerts << alert
      when status == 'stale'
        stale_alerts << alert
      when is_suppressed?(status)
        silenced_alerts << alert
      end
    end

    output = ""

    if firing_alerts.present?
      output += "## :fire: #{I18n.t("prom_alert_receiver.post.headers.firing")}\n\n"
      output = generate_alert_items(firing_alerts, output)
    end

    if silenced_alerts.present?
      output += "\n\n# :shushing_face: Silenced Alerts\n\n"
      output = generate_alert_items(silenced_alerts, output)
    end

    {
      "history" => resolved_alerts,
      "stale" => stale_alerts
    }.each do |header, alerts|
      if alerts.present?
        header = I18n.t("prom_alert_receiver.post.headers.#{header}")
        output += "\n\n## #{header}\n\n"
        output = generate_alert_items(alerts, output)
      end
    end

    output
  end

  def thead(alerts)
    base_key = "prom_alert_receiver.post.table.thead"
    label = I18n.t("#{base_key}.label")
    time_range = I18n.t("#{base_key}.time_range")

    headers = "| #{label} | #{time_range} |"
    cells = "| --- | --- |"

    if alerts.any? { |alert| alert['description'] }
      description = I18n.t("#{base_key}.description")
      headers += " #{description} |"
      cells += " --- |"
    end

    "#{headers}\n#{cells}"
  end

  def alert_item(alert)
    item = "| [#{alert['id']}](#{alert_link(alert)}) | #{alert_time_range(alert)} |"

    if description = alert['description']
      item += " #{description} |"
    end

    item
  end

  def alert_time_range(alert)
    if alert['ends_at']
      "#{local_date(alert['starts_at'])} to #{local_date(alert['ends_at'])}"
    else
      "active since #{local_date(alert['starts_at'])}"
    end
  end

  def local_date(time)
    parsed = Time.zone.parse(time)

    date = <<~DATE
    [date=#{parsed.strftime("%Y-%m-%d")} time=#{parsed.strftime("%H:%M:%S")} format="L LTS" forceTimeZone="UTC" timezones="Europe/Paris\\|America/Los_Angeles\\|Asia/Singapore\\|Australia/Sydney"]
    DATE

    date.chomp!
    date
  end

  def alert_link(alert)
    url = URI(alert['graph_url'])
    url_params = CGI.parse(url.query)

    begin_t = Time.parse(alert['starts_at'])
    end_t   = Time.parse(alert['ends_at']) rescue Time.zone.now
    url_params['g0.range_input'] = "#{(end_t - begin_t).to_i + 600}s"
    url_params['g0.end_input']   = "#{(end_t + 300).strftime("%Y-%m-%d %H:%M")}"
    url.query    = URI.encode_www_form(url_params)
    url.fragment = "graph0"

    url.to_s
  end

  def prev_topic_link(topic_id)
    return "" if topic_id.nil?
    created_at = Topic.where(id: topic_id).pluck(:created_at).first
    return "" unless created_at

    "([Previous alert topic created.](#{Discourse.base_url}/t/#{topic_id}) #{local_date(created_at.to_s)})\n\n"
  end

  def first_post_body(receiver:,
                      topic_body: "",
                      alert_history:,
                      prev_topic_id:)

    output = ""
    output += "#{topic_body}\n\n"
    output += "#{prev_topic_link(prev_topic_id)}\n\n" if prev_topic_id
    output += "#{render_alerts(alert_history)}\n"
  end

  def revise_topic(topic:, title:, raw:, datacenters:, firing: nil, high_priority: false)
    post = topic.posts.first
    title_changed = topic.title != title
    skip_revision = !title_changed

    if post.raw.strip != raw.strip || title_changed || !firing.nil?
      post = topic.posts.first

      fields = {
        title: title,
        raw: raw
      }

      fields[:tags] ||= []

      if datacenters.present?
        fields[:tags] = topic.tags.pluck(:name)
        fields[:tags].concat(datacenters)
        fields[:tags].uniq!
      end

      fields[:tags] << HIGH_PRIORITY_TAG.dup if high_priority

      if firing
        fields[:tags] << FIRING_TAG.dup
      else
        fields[:tags].delete(FIRING_TAG)
      end

      PostRevisor.new(post, topic).revise!(
        Discourse.system_user,
        fields,
        skip_revision: skip_revision,
        skip_validations: true,
        validate_topic: true # This is a very weird API
      )
    end
  end

  def is_suppressed?(status)
    "suppressed".freeze == status
  end

  def is_firing?(status)
    status == "firing".freeze
  end

  def datacenters(alerts)
    alerts.each_with_object(Set.new) do |alert, set|
      set << alert['datacenter'] if alert['datacenter']
    end.to_a
  end

  def generate_alert_items(grouped_alerts, output)
    grouped_alerts
      .group_by { |alert| [alert['datacenter'], alert['external_url']] }
      .each do |(datacenter, external_url), alerts|

      output += "### [#{datacenter}](#{external_url})\n\n#{thead(alerts)}\n"
      output += alerts.map { |alert| alert_item(alert) }.join("\n")
      output += "\n\n"
    end

    output
  end
end
