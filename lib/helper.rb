module Helper

  def humanize_time secs
    [[60, :seconds], [60, :minutes], [24, :hours], [10000, :days]].map{ |count, name|
      if secs > 0
        secs, n = secs.divmod(count)
        if n.to_i > 1
          "#{n.to_i} #{name}"
        else
          "#{n.to_i} #{name.to_s.gsub(/s$/,'')}"
        end
      end
    }.compact[-1]
  end

  def full_title(page_title)
    base_title = "Pixel"
    if page_title.empty?
      base_title
    else
      "#{base_title} | #{page_title}"
    end
  end

  def tr_attributes(oids, opts={})
    attributes = [
      "data-toggle='tooltip'",
      "data-container='body'",
      "title='index: #{oids[:index]}'",
      "data-rel='tooltip-left'",
        "data-pxl-index='#{oids[:index]}'"
    ]
    attributes.push "data-pxl-parent='#{oids[:my_parent]}'" if oids[:is_child] && opts[:hl_relation]
    classes = []

    if oids[:is_child]
      classes.push("#{oids[:my_parent]}_child") if opts[:hl_relation]
      classes.push('panel-collapse collapse out') if opts[:hide_if_child]
      classes.push('pxl-child-tr') if opts[:hl_relation]
    end

    attributes.join(' ') + " class='#{classes.join(' ')}'"
  end

  def bps_cell(direction, oids, opts={:pct_precision => 2})
    pct_precision = opts[:pct_precision]
    units = :bps
    # If bps_in/Out doesn't exist, return blank
    return '' unless oids["bps_#{direction}".to_sym] && oids[:link_up]
    util = ("%.3g" % oids["bps_#{direction}_util".to_sym]) + '%'
    if opts[:compact]
      util.gsub!(/\.[0-9]+/,'')
      units = :si_short
    end
    traffic = number_to_human(oids["bps_#{direction}".to_sym], units, true, '%.3g')
    return traffic if opts[:bps_only]
    return util if opts[:pct_only]
    return "#{util} (#{traffic})"
  end

  def total_bps_cell(interfaces, oids)
    # If interface is child, set total to just under parent total,
    # so that the interface is sorted to sit directly under parent
    # when tablesorter runs.
    if oids[:is_child]
      p_oids = interfaces[oids[:my_parent]]
      if p_oids && p_oids[:bps_in] && p_oids[:bps_out]
        p_total = p_oids[:bps_in] + p_oids[:bps_out]
        me_total = (oids[:bps_in] || 0) + (oids[:bps_out] || 0)
        offset = me_total / (oids[:if_high_speed].to_f * 1000000) * 10
        return p_total - 20 + offset
      else
        return '0'
      end
    end
    # If not child, just return the total bps
    oids[:bps_in] + oids[:bps_out] if oids[:bps_in] && oids[:bps_out]
  end

  def speed_cell(oids)
    return '' unless oids[:link_up]
    speed_in_bps = oids[:if_high_speed] * 1000000
    number_to_human(speed_in_bps, :bps, true, '%.0f')
  end

  def neighbor_link(oids, opts={})
    if oids[:neighbor]
      neighbor = oids[:neighbor] ? "<a href='/device/#{oids[:neighbor]}'>#{oids[:neighbor]}</a>" : oids[:neighbor]
      port = oids[:if_alias][/__[0-9a-zA-Z\-.: \/]+$/] || ''
      port.empty? || opts[:device_only] ? neighbor : "#{neighbor} (#{port.gsub('__','')})"
    elsif oids[:if_type] == 'unknown'
      oids[:if_alias]
    else
      ''
    end
  end

  def device_link_graph(settings, device, text)
    "<a href='#{settings['grafana_dev_dash']}?device=#{device}" +
    "' target='_blank'>#{text}</a>"
  end

  def interface_link(settings, oids)
    "<a href='#{settings['grafana_if_dash']}" +
      "?title=#{oids[:device]}%20::%20#{CGI::escape(oids[:if_name])}" +
    "&name=#{oids[:device]}.#{oids[:index]}" +
    "&ifSpeedBps=#{oids[:if_high_speed].to_i * 1000000 }" +
    "&ifMaxBps=#{[ oids[:bps_in].to_i, oids[:bps_out].to_i ].max}" + 
                   "' target='_blank'>" + oids[:if_name] + '</a>'
  end

  def alarm_type_text(data)
    text = ''
    text << "<span class='text-danger'>RED</span> " if data[:red_alarm] && data[:red_alarm] != 2
    text << "and " if data[:red_alarm] && data[:red_alarm] != 2 && data[:yellow_alarm] && data[:yellow_alarm] != 2
    text << "<span class='text-warning'>YELLOW</span> " if data[:yellow_alarm] && data[:yellow_alarm] != 2
  end

  def device_link(data)
    "<a href='/device/#{data[:device]}'>#{data[:device]}</a>"
  end

  def link_status_color(interfaces,oids)
    return 'grey' if oids[:stale]
    return 'darkRed' if oids[:if_admin_status] == 2
    return 'red' unless oids[:link_up]
    return 'orange' if !oids[:discards_out].to_s.empty? && oids[:discards_out] != 0
    return 'orange' if !oids[:errors_in].to_s.empty? && oids[:errors_in] != 0
    # Check children -- return orange unless all children are up
    if oids[:is_parent]
      oids[:children].each do |child_index|
        return 'orange' unless interfaces[child_index][:link_up]
      end
    end
    return 'green'
  end

  def link_status_tooltip(interfaces,oids)
    shutdown = oids[:if_admin_status] == 2 ? "Shutdown\n" : ''
    discards = oids[:discards_out] || 0
    errors = oids[:errors_in] || 0
    stale_warn = oids[:stale] ? "Last polled: #{humanize_time(oids[:stale])} ago\n" : ''
    discard_warn = discards == 0 ? '' : "#{discards} outbound discards/sec\n"
    error_warn = errors == 0 ? '' : "#{errors} receive errors/sec\n"
    child_warn = ''
    if oids[:is_parent]
      oids[:children].each do |child_index|
        child_warn = "Child link down\n" unless interfaces[child_index][:link_up]
      end
    end
    state = oids[:link_up] ? 'Up' : 'Down'
    time = humanize_time(Time.now.to_i - oids[:if_oper_status_time])
    return shutdown + stale_warn + discard_warn + error_warn + child_warn + "#{state} for #{time}"
  end


  def sw_tooltip(data)
    if data[:vendor] && data[:sw_descr] && data[:sw_version]
      "running #{data[:sw_descr]} #{data[:sw_version]}"
    else
      "No software data found"
    end
  end


  def count_children(devices, type=[:all])

    count = 0

    devices.each do |dev,data|
      count += 1 if ( type.include?(:devicedata) || type.include?(:all) ) && data[:devicedata]
      count += (data[:cpus] || {}).count if type.include?(:cpus) || type.include?(:all)
      count += (data[:fans] || {}).count if type.include?(:fans) || type.include?(:all)
      count += (data[:psus] || {}).count if type.include?(:psus) || type.include?(:all)
      count += (data[:memory] || {}).count if type.include?(:memory) || type.include?(:all)
      count += (data[:interfaces] || {}).count if type.include?(:interfaces) || type.include?(:all)
      count += (data[:temperatures] || {}).count if type.include?(:temperatures) || type.include?(:all)
    end

    return count
  end


  def number_to_human(raw, unit, si=true, format='%.2f')
    i = 0
    units = {
      :bps => [' bps', ' Kbps', ' Mbps', ' Gbps', ' Tbps', ' Pbps', ' Ebps', ' Zbps', ' Ybps'],
      :pps => [' pps', ' Kpps', ' Mpps', ' Gpps', ' Tpps', ' Ppps', ' Epps', ' Zpps', ' Ypps'],
      :si_short => [' b', ' K', ' M', ' G', ' T', ' P', ' E', ' Z', ' Y'],
    }
    step = si ? 1000 : 1024
    while raw >= step do
      raw = raw.to_f / step
      i += 1
    end

    return (sprintf format % raw).to_s + ' ' + units[unit][i]
  end


  def epoch_to_date(value, format='%-d %B %Y, %H:%M:%S UTC')
    DateTime.strptime(value.to_s, '%s').strftime(format)
  end


  def devicedata_to_human(oid, value, opts={})
    oids_to_modify = [ :bps_out, :pps_out, :discards_out, :uptime, :last_poll_duration, 
                       :last_poll, :next_poll, :currently_polling, :last_poll_result,
                       :yellow_alarm, :red_alarm ]
    # abort on empty or non-existant values
    return value unless value && !value.to_s.empty?
    return value unless oids_to_modify.include?(oid)

    output = "#{value} (" if opts[:add]

    output << number_to_human(value, :bps) if oid == :bps_out
    output << number_to_human(value, :pps) if [ :pps_out, :discards_out ].include?(oid)
    output << humanize_time(value) if [ :uptime, :last_poll_duration ].include?(oid)
    output << epoch_to_date(value) if [ :last_poll, :next_poll ].include?(oid)
    output << (value == 1 ? 'Yes' : 'No') if oid == :currently_polling
    output << (value == 1 ? 'Failure' : 'Success') if oid == :last_poll_result
    output << (value == 2 ? 'Inactive' : 'Active') if [ :yellow_alarm, :red_alarm ].include?(oid)

    output << ")" if opts[:add]
    return output
  end

end
