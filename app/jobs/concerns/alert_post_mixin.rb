module AlertPostMixin
  extend ActiveSupport::Concern

  private

  def render_alerts(alert_history)
    firing_alerts = []
    resolved_alerts = []
    silenced_alerts = []

    alert_history.each do |alert|
      status = alert['status']

      case
      when is_firing?(status)
        firing_alerts << alert
      when status == 'resolved'
        resolved_alerts << alert
      when is_suppressed?(status)
        silenced_alerts << alert
      end
    end

    output = ""

    if firing_alerts.length > 0
      output += "# :fire: Firing Alerts\n\n"

      output += firing_alerts.map do |alert|
        <<~BODY
        #{alert_item(alert)}
        #{alert['description']}
        BODY
      end.join("\n")
    end

    if silenced_alerts.length > 0
      output += "\n\n# :shushing_face: Silenced Alerts\n\n"

      output += silenced_alerts.map do |alert|
        <<~BODY
        #{alert_item(alert)}
        #{alert['description']}
        BODY
      end.join("\n")
    end

    if resolved_alerts.length > 0
      output += "\n\n# Alert History\n\n"
      output += resolved_alerts.map { |alert| alert_item(alert) }.join("\n")
    end

    output
  end

  def alert_item(alert)
    " * [#{alert_label(alert)}](#{alert_link(alert)})"
  end

  def alert_label(alert)
    "#{alert['id']} (#{alert_time_range(alert)})"
  end

  def alert_time_range(alert)
    if alert['ends_at']
      "#{friendly_time(alert['starts_at'])} to #{friendly_time(alert['ends_at'])}"
    else
      "active since #{friendly_time(alert['starts_at'])}"
    end
  end

  def friendly_time(t)
    Time.parse(t).strftime("%Y-%m-%d %H:%M:%S UTC")
  end

  def alert_link(alert)
    url = URI(alert['graph_url'])
    url_params = CGI.parse(url.query)

    begin_t = Time.parse(alert['starts_at'])
    end_t   = Time.parse(alert['ends_at']) rescue Time.now
    url_params['g0.range_input'] = "#{(end_t - begin_t).to_i + 600}s"
    url_params['g0.end_input']   = "#{end_t.strftime("%Y-%m-%d %H:%M")}"
    url.query = URI.encode_www_form(url_params)

    url.to_s
  end

  def prev_topic_link(topic_id)
    return "" if topic_id.nil?
    created_at = Topic.where(id: topic_id).pluck(:created_at).first
    return "" unless created_at

    "([Previous alert topic created `#{created_at.to_formatted_s}`.](#{Discourse.base_url}/t/#{topic_id}))\n\n"
  end

  def topic_title(alert_history: nil, datacenter:, topic_title:, firing: nil)
    firing ||= alert_history.all? do |alert|
      is_firing?(alert["status"])
    end

    (firing ? ":fire: " : "") + (datacenter || "") + topic_title
  end

  def first_post_body(receiver:,
                      external_url:,
                      topic_body: "",
                      alert_history:,
                      prev_topic_id:)

    <<~BODY
    #{external_url}

    #{topic_body}

    #{prev_topic_link(prev_topic_id)}

    #{render_alerts(alert_history)}
    BODY
  end

  def is_suppressed?(status)
    "suppressed".freeze == status
  end

  def is_firing?(status)
    status == "firing".freeze
  end
end
