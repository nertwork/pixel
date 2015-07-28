# admin_status_event.rb
#
require_relative 'component_status_event'

class AdminStatusEvent < ComponentStatusEvent


  def self.friendly_subtype
    'Admin Status'
  end


  def html_details(int=nil)
    if @new == 'Down'
      status_class = 'text-danger'
      verb = 'was set'
    else # Up
      status_class = 'text-success'
      verb = 'was set'
    end

    if int
      "Interface #{int.name} on #{@device} #{verb} <span class='#{status_class}'><b>Admin #{@new}</b></span>"
    else
      "Interface w/ index #{@index} on #{@device} #{verb} <span class='#{status_class}'><b>Admin #{@new}</b></span>"
    end
  end


end
