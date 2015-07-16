# component.rb
#
require 'logger'
require_relative 'api'

$LOG ||= Logger.new(STDOUT)


class Component


  def self.fetch(device, index, hw_type)
    obj = API.get(
      src: 'component',
      dst: 'core',
      resource: "/v2/device/#{device}/#{hw_type.downcase}/#{index}",
      what: "#{hw_type} #{index} on #{device}",
    )
    obj.is_a?(Component) ? obj : nil
  end


  def self.fetch_from_db(device: nil, index: nil, hw_type: nil, id: nil, db:, limit: nil)

    comp_data = db[:component]
    # Filter if options were passed
    comp_data = comp_data.where(:id => id) if id
    comp_data = comp_data.where(:device => device) if device
    comp_data = comp_data.where(:hw_type => hw_type) if hw_type
    comp_data = comp_data.where(:index => index) if index
    comp_data = comp_data.limit(limit) if limit && limit.to_s =~ /^\d+$/

    components = []
    comp_data.select_all.each do |row|
      component = Object::const_get(row[:hw_type]).new(
        device: row[:device], hw_type: row[:hw_type], index: row[:index],
      )
      components.push(component.populate(row))
    end

    return components
  end


  def self.id(device:, index:, hw_type:)
    return nil if (device.to_s.empty? || index.to_s.empty? || hw_type.to_s.empty?)
    obj = API.get(
      src: 'component',
      dst: 'core',
      resource: "/v2/device/#{device}/#{hw_type}/#{index}/id",
      what: "ID value for #{hw_type} #{index} on #{device}",
    )
    obj['id']
  end


  def self.id_from_db(device:, index:, hw_type:, db:)
    unless device && index && hw_type
      $LOG.error("COMPONENT: Can't fetch ID from db. Device: #{device}, hw_type: #{hw_type}, index: #{index}")
      return nil
    end
    component = db[:component].where(
      :hw_type=>hw_type,
      :device=>device,
      :index=>index
    ).first
    return component[:id] if component
    return nil
  end


  def initialize(device:, index:, hw_type:)
    @device = device
    @index = index.to_s
    @hw_type = hw_type
  end


  def device
    @device
  end


  def index
    @index
  end


  def description
    @description || ''
  end


  def last_updated
    @last_updated || 0
  end


  def hw_type
    @hw_type
  end


  def events
    @events || []
  end


  def populate(data)
    # Required in order to accept symbol and non-symbol keys
    data = data.symbolize

    # Return nil if we didn't find any data
    # TODO: Raise an exception instead?
    return nil if data.empty?

    @description = data[:description].to_s
    @last_updated = data[:last_updated].to_i_if_numeric
    @worker = data[:worker]
    @events = data[:events]

    return self
  end


  def update(data, worker:)
    new_description = data['description'] || "#{@hw_type} #{@index}"
    new_description.delete!("\0")
    current_time = Time.now.to_i
    new_worker = worker

    # Generate events if things have changed
    @events ||= []

    # Description change
    if new_description != @description
      @events.push(DescriptionEvent.new(
        device: @device, hw_type: @hw_type, index: @index,
        old: @description, new: new_description
      ))
    end

    # Update values
    @description = new_description
    @last_updated = current_time
    @worker = new_worker

    return self
  end


  def save(db)
    data = {}
    data[:device] = @device
    data[:hw_type] = @hw_type
    data[:index] = @index
    data[:description] = description
    data[:last_updated] = @last_updated if @last_updated
    data[:worker] = @worker if @worker

    # Update the component table
    existing = db[:component].where(:hw_type=>@hw_type, :device=>@device, :index=>@index)
    if existing.update(data) != 1
      $LOG.info("#{@hw_type}: Adding #{@index} (#{@description}) on #{@device} from #{@worker}")
      db[:component].insert(data)
    end

    # Get @id if we don't already have it
    @id = existing.first[:id] unless @id
    raise "No component id! #{@index} (#{@description}) on #{@device} from #{@worker}" unless @id

    # Update the component_event table
    if @events
      @events.each do |event|
        event.set_component_id(@id)
        event.save(db)
      end
    end

    return self
  end


  def delete(db)
    $LOG.info(
      "#{@hw_type}: Attempting to delete #{@index} (#{@description}) on #{@device}. " +
      "Last poller: #{@worker}"
    )

    db[:component].where(
      :hw_type => @hw_type,
      :device => @device,
      :index => @index
    ).delete
  end


  def to_json(*a)
    hash = {
      "json_class" => self.class.name,
      "data" => {}
    }

    hash['data']["device"] = @device
    hash['data']["index"] = @index
    hash['data']["description"] = description
    hash['data']["last_updated"] = @last_updated if @last_updated
    hash['data']["worker"] = @worker if @worker
    hash['data']["events"] = events unless events.empty?

    hash.to_json(*a)
  end


  def self.json_create(json)
    data = json["data"]
    Component.new(device: data['device'], index: data['index']).populate(data)
  end


end
