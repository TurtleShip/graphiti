require 'rubygems'
require 'bundler'
Bundler.setup

if !defined?(RACK_ENV)
  RACK_ENV = ENV['RACK_ENV'] || 'development'
end

require 'sinatra/base'
require 'sinatra/contrib'
require 'redis/namespace'
require 'compass'
require 'typhoeus'
require 'yajl'
require 'digest/sha1'
require 'pp'

require './lib/s3/request'
require './lib/s3/signature'
require './lib/redised'

require './lib/metric'
require './lib/graph'
require './lib/dashboard'
require 'sinatra/static_assets'

require 'csv'
require 'uri'
require 'open-uri'
require 'json'


class Graphiti < Sinatra::Base

  VERSION = '0.1.0'

  register Sinatra::Contrib
  register Sinatra::StaticAssets

  config_file 'config/settings.yml'

  configure do
    set :logging, true
    Compass.configuration do |config|
      config.project_path = settings.root
      config.sass_dir = File.join(settings.views, 'stylesheets')
      config.output_style = :compact
    end
    set :haml, :format => :html5
    set :scss, Compass.sass_engine_options
    set :method_override, true
    Graph.redis = settings.redis_url
    Dashboard.redis = settings.redis_url
    Metric.redis = settings.redis_url
  end

  before do
    S3::Request.logger = logger
  end


  ## endpoints for automation
  ## All return values are given in JSON format
  # Change all method types to POST later on
  # I am using GET to make testing/debugging easier

  def encode_option(option, value)
    "&#{option}=#{value}"
  end

  def build_url_from_json(json_data)
    url = "http://#{Graphiti.settings.graphite_host}/render/?"

    options = json_data['options']
    options.each do |key, value|
      url += encode_option(key, value)
    end

    targets = json_data['targets']
    targets.each do |target|
      url += encode_option("target", target[0])
    end

    url += "&_timestamp_=#{Time.now.to_i}#.png"
    url = URI.escape(url)

    url
  end

  ## creates and saves a graph. Return the graph id
  post '/auto/graph/create' do

    pp params
    # params
    # will have { title, from, until}

    # Create a new graph
    base_url = "http://#{Graphiti.settings.graphite_host}/render/?"
    url = base_url + "width=950&height=400"

    url += encode_option("title", params[:title])
    url += encode_option("from", params[:from])

    if not params[:until]
      url += encode_option("until", params[:until])
    end


    # default options
    url += encode_option("fontSize", "10")
    url += encode_option("fontName", "DroidSans")
    url += encode_option("lineMode", "slope")
    url += encode_option("thickness", "2")
    url += encode_option("bgcolor", "%23FFFFFF")
    url += encode_option("fgcolor", "%23333333")
    url += encode_option("majorGridLineColor", "%23ADADAD")
    url += encode_option("minorGridLineColor", "%23E5E5E5")

    # set targets
    metrics = params[:metrics] # list of metrics to plot to this graph
    metrics.each do |name|
      url += encode_option("target", name)
    end

    graph_data = {}.to_json # create an empty json
    ## Refer to graph.rb to figure out what kind of data to feed
    # url should look something like this
    graph_data[:title] = params[:title]
    graph_data[:json] ## huh?
    graph_data[:url] = url

    graph_id = Graph.save(graph_data)



    # Grab a dashboard
    dashboard_name = params[:dashboard_name]

    if dashboard_name == nil
      # Add it to automation dashboard
    else
      # add it to the specified dashboard id
    end

    # Return the graph id id
    content_type :json
    { :graph_id => graph_id }.to_json
  end

  ## Update an existing graph
  post '/auto/graph/update' do
    pp params

    graph = Graph.find(params[:graph_id])

    if graph == nil
      puts "Could not find graph #{params[:graph_id]}"
      return
    end

    # update json, which is used to create graph UI in graphiti
    json_data = JSON.parse(graph['json'])
    json_data['options']['from'] = params[:from]
    json_data['options']['until'] = params[:until]
    json_data['options']['title'] = params[:title]

    # update url, which will be used to take a snapshot
    url = build_url_from_json( json_data )

    graph_data = {}
    graph_data[:title] = params[:title]
    graph_data[:json] = json_data.to_json
    graph_data[:url] = url
    Graph.save(params[:graph_id], graph_data)
  end

  post '/auto/graph/destroy' do
    pp params
    Graph.destroy( params[:graph_id] )
  end

  ## Takes a snapshot and returns the location of snapshot in S3 store
  post '/auto/graph/snapshot' do
    graph_id = params[:graph_id]
    url = Graph.snapshot(graph_id)
    json :url => url
  end

  get '/auto/graph/info' do

    graph = Graph.find(params[:graph_id])
    graph['json'] = JSON.parse(graph['json'])
    parsed = JSON.parse( graph.to_json )
    json parsed

  end


  post '/auto/dashboard/create' do
    # Create a new dashboard with the given name
    pp params
    dashboard_data = {:slug => params[:dashboard_name], :title => params[:title]}.to_json
    dashboard = Dashboard.save(params)

    # return new dashboard
    json :dashboard => dashboard
  end

  post '/auto/dashboard/destroy' do
    pp params
    Dashboard.destroy(params[:dashboard_name])
  end

  get '/auto/dashboard/info' do
    # return everything about this dashboard
    pp params
    display_graph = params[:with_graph] == "true"
    json Dashboard.find( params[:dashboard_name], display_graph )
  end


  post '/auto/dashboard/snapshot' do
    ## NEED BELOW PARAMS
    # required: { dashboard_name, snapshot_group_name }
    # optional: { from, until }

    pp params

    dashboard = Dashboard.find( params[:dashboard_name] )
    graph_ids = dashboard['graphs']
    snapshots = Hash.new

    # go through each graph and take a snapshot
    # save {key, value} as { graph_id, url to the snapshot }
    graph_ids.each do |graph_id|

      # Update time range if specified by a user
      if params[:from] != nil and params[:from] != "" and params[:until] != nil and params[:until] != ""
        graph = Graph.find( graph_id )

        if graph == nil
          puts "Could not find graph #{graph_id}"
          next
        end

        # update json, which is used to create graph UI in graphiti
        json_data = JSON.parse(graph['json'])
        json_data['options']['from'] = params[:from]
        json_data['options']['until'] = params[:until]

        # update url, which will be used to take a snapshot
        url = build_url_from_json( json_data )

        graph_data = {}
        graph_data[:title] = graph['title']
        graph_data[:json] = json_data.to_json
        graph_data[:url] = url
        Graph.save(graph_id, graph_data)
      end

      puts "Trying graph #{graph_id}"
      url = Graph.snapshot(graph_id)
      snapshots[graph_id] = url
    end

    # Save all {key, value} under {snapshot_group_name }
    Dashboard.save_snapshots( params[:dashboard_name], params[:snapshot_group_name], snapshots )
  end



  get '/auto/dashboard/snapshot' do
    # NEED BELOW PARAMS
    # { dashboard_name }
    pp params

    # find the snapshot_group and display all snapshots with their corresponding url
    @dashboard_name = params[:dashboard_name]
    @snapshot_group_name = params[:snapshot_group_name]

    @snapshot_groups = Dashboard.load_snapshot_groups( @dashboard_name )
    @snapshots = Hash.new


    @snapshot_groups.each do |snapshot_group|
      cur_snapshots = Dashboard.load_snapshots( @dashboard_name, snapshot_group )
      cur_data = Array.new
      cur_snapshots.each do |group_id, image_url|
        cur_data.push( [group_id, image_url] )
      end
      @snapshots[snapshot_group] = cur_data
    end

    erb :dashboard_snapshots
  end


  def format_point( pt )
    if pt == 'None'
      #return nil.to_json
      return 0
    end
    return pt.to_f
  end

  # Compare snapshots between two different snapshot groups with the same dashboard
  get '/compare/dashboards' do
    pp params

    ## Need below params
    # {:dashboard_name, :snapshot_group_one_name, :snapshot_group_two_name }

    @dashboard_name = params[:dashboard_name]
    @snapshot_group_one_name = params[:snapshot_group_one_name]
    @snapshot_group_two_name = params[:snapshot_group_two_name]

    #pull all snapshots from both snapshot groups
    @snapshot_group_one = Dashboard.load_snapshots( @dashboard_name, @snapshot_group_one_name )
    @snapshot_group_two = Dashboard.load_snapshots( @dashboard_name, @snapshot_group_two_name )

    #compare one by one, and do comparison only on the ones that have the same graph id.
    # return comparison result by { graph_id => { metric_name => {max_dev, std_dev}, url => link_to_comparison_url }

    @result = Hash.new
    @snapshot_group_one.each do | graph_id, sp_one_url |
      if @snapshot_group_two[graph_id] == nil
        next
      end
      # we have a match. do comparison
      sp_two_url = @snapshot_group_two[graph_id]
      cur_result = compare_sp( sp_one_url, sp_two_url, false ) #we need only comparison result

      # save only what is necessary
      @result[graph_id] = Hash.new
      @result[graph_id][:sp_one_url] = sp_one_url
      @result[graph_id][:sp_two_url] = sp_two_url
      @result[graph_id][:compared_metrics] = cur_result[:compared_metrics]
      @result[graph_id][:std_dev] = cur_result[:std_dev]
      @result[graph_id][:max_dev] = cur_result[:max_dev]
      @result[graph_id][:total_data_pt] = cur_result[:total_data_pt]
    end

    if params[:want_json] == "true"
      parsed = JSON.parse(@result.to_json)
      json parsed
    else
      erb :compare_dashboards
    end


  end

  get '/compare/snapshots' do
    pp params

    res = compare_sp( params[:snapshot_one], params[:snapshot_two], true )

    @sp_one_image_url = params[:snapshot_one]
    @sp_two_image_url = params[:snapshot_two]
    @has_solid_data = res[:has_solid_data]
    @has_same_time_series = res[:has_same_time_series]
    @std_dev = res[:std_dev]
    @max_dev = res[:max_dev]
    @total_data_pt = res[:total_data_pt]
    @compared_metrics = res[:compared_metrics]
    @unmatched_metrics = res[:unmatched_metrics]
    @sp_one_raw_url = res[:sp_one_raw_url]
    @sp_two_raw_url = res[:sp_two_raw_url]
    @sp_one_data_series = res[:sp_one_data_series]
    @sp_two_data_series = res[:sp_two_data_series]
    @time_series = res[:time_series]

    if params[:want_json] == "true"
      parsed = JSON.parse(res.to_json)
      json parsed

    else
      erb :compare_snapshots
    end

  end

  get '/graphs/:uuid.js' do
    json Graph.find(params[:uuid])
  end

  get '/metrics.js' do
    json :metrics => Metric.find(params[:q])
  end

  get '/graphs.js' do
    json :graphs => Graph.all
  end

  get '/dashboards/:slug.js' do
    json Dashboard.find(params[:slug], true)
  end

  get '/dashboards.js' do
    if params[:uuid]
      json :dashboards => Dashboard.without_graph(params[:uuid])
    else
      json :dashboards => Dashboard.all
    end
  end

  post '/graphs' do
    uuid = Graph.save(params[:graph])
    json :uuid => uuid
  end



  post '/graphs/:uuid/snapshot' do
    url = Graph.snapshot(params[:uuid])
    json :url => url
  end

  put '/graphs/:uuid' do
    uuid = Graph.save(params[:uuid], params[:graph])
    json :uuid => uuid
  end

  post '/dashboards' do
    dashboard = Dashboard.save(params[:dashboard])
    json :dashboard => dashboard
  end

  post '/graphs/dashboards' do
    json Dashboard.add_graph(params[:dashboard], params[:uuid])
  end

  delete '/graphs/dashboards' do
    json Dashboard.remove_graph(params[:dashboard], params[:uuid])
  end

  delete '/graphs/:uuid' do
    Graph.destroy(params[:uuid])
  end

  delete '/dashboards/:slug' do
    Dashboard.destroy(params[:slug])
  end

  post '/snapshot' do
    filename = Graph.snapshot(params[:uuid])
    json :filename => filename
  end

  # Routes that are entirely handled by Sammy/frontend
  # and just need to load the empty index
  %w{
    /graphs/workspace
    /graphs/new
    /graphs/:uuid
    /graphs/:uuid/snapshots
    /graphs
    /dashboards/:slug
    /dashboards
    /
  }.each do |path|
    get path do
      haml :index
    end
  end

  get '/stylesheets/:name.css' do
    content_type 'text/css'
    scss :"stylesheets/#{params[:name]}"
  end

  def default_graph
    {
      :options => settings.default_options,
      :targets => settings.default_metrics.collect {|m| [m, {}] }
    }
  end


=begin
input
:snapshot_one_image_url, :snapshot_two_image_url, need_all_data
NOTE
  If need_all_data is true, more output is provided.
  Refer to the below

output (Stored in has form. ex> result[:has_solid_data] = true)
deafult:
  compared_metrics : Array
  std_dev : Array
  max_dev : Array
  total_data_pt : Array

if need_all_data is true:
  unmatched_metrics : Array
  has_solid_data : boolean
  has_same_time_series : boolean
  sp_one_raw_url
  sp_two_raw_url
  sp_one_data_series
  sp_two_data_series
  time_series
=end
  ## TODO: Refactor this to a separate class that handles analysis
  def compare_sp( sp_one_image_url, sp_two_image_url, need_all_data )
    puts "sp_one_image_url : #{sp_one_image_url}"
    puts "sp_two_image_url : #{sp_two_image_url}"

    result = Hash.new

    ## Comparison between two data sets with different time series steps
    ## (interval between each data point) is not allowed
    has_solid_data = true
    has_same_time_series = true
    std_dev = Array.new
    max_dev = Array.new
    total_data_pt = Array.new
    compared_metrics = Array.new
    unmatched_metrics = Array.new

    # get raw data urls from image urls
    sp_one_raw_url = String.new(sp_one_image_url)
    sp_one_raw_url.sub! 'image', 'raw'
    sp_one_raw_url.sub! 'png', 'csv'

    sp_two_raw_url = String.new(sp_two_image_url)
    sp_two_raw_url.sub! 'image', 'raw'
    sp_two_raw_url.sub! 'png', 'csv'

    # download raw data from S3 store
    sp_one_raw_file = CSV.new(open(sp_one_raw_url))
    sp_two_raw_file = CSV.new(open(sp_two_raw_url))

    sp_one_rows = sp_one_raw_file.readlines
    sp_two_rows = sp_two_raw_file.readlines

    if sp_one_rows.size == 0 or sp_two_rows.size == 0
      has_solid_data = false

      return
    end

    sp_one_time_series = sp_one_rows[0][3].split('|')[0]
    sp_two_time_series = sp_two_rows[0][3].split('|')[0]

    # check for time series step match
    if sp_one_time_series != sp_two_time_series
      has_same_time_series = false

      return
    end
    time_series = sp_one_time_series


    # extract data series
    sp_one_data_series = Array.new
    sp_two_data_series = Array.new


    idx = 0
    sp_one_rows.each do |sp_one_line|

      # go through sp_two_raw_file and find a matching metrics
      sp_two_rows.each do |sp_two_line|
        if sp_one_line[0] != sp_two_line[0]
          next
        end

        compared_metrics.push( sp_one_line[0] )
        total_data_pt.push(0)
        std_dev.push(0)
        max_dev.push(0)

        sp_one_cur_data = Array.new
        sp_two_cur_data = Array.new


        # Note that snapshot will always have its first data point (whether it is None or a number )
        # because you can't take a snapshot with no data
        pt_one = sp_one_line[3].split('|')[1]
        pt_two = sp_two_line[3].split('|')[1]

        sp_one_cur_data.push( format_point( pt_one ) )
        sp_two_cur_data.push( format_point( pt_two ) )


        if pt_one != 'None' and pt_two != 'None'
          pt_one = pt_one.to_f
          pt_two = pt_two.to_f
          total_data_pt[idx] += 1
          cur_dev = (pt_one - pt_two).abs
          std_dev[idx] += cur_dev
          max_dev[idx] = [max_dev[idx], cur_dev].max
        end

        data_last_idx = [ sp_one_line.length, sp_two_line.length ].min - 1
        for i in 4..(data_last_idx)
          pt_one = sp_one_line[i]
          pt_two = sp_two_line[i]

          sp_one_cur_data.push( format_point( pt_one ) )
          sp_two_cur_data.push( format_point( pt_two ) )

          if pt_one == 'None' or pt_two == 'None'
            next
          end
          pt_one = pt_one.to_f
          pt_two = pt_two.to_f

          total_data_pt[idx] += 1
          cur_dev = (pt_one - pt_two).abs
          std_dev[idx] += cur_dev
          max_dev[idx] = ([max_dev[idx], cur_dev].max).round(10)
        end

        sp_one_data_series.push( sp_one_cur_data )
        sp_two_data_series.push( sp_two_cur_data )

        if total_data_pt[idx] == 0
          std_dev[idx] = 0.0
        else
          # round up to 5th decimal place
          std_dev[idx] = (std_dev[idx] / total_data_pt[idx]).round(10)
        end

        idx += 1

        break
      end ## end of inner for loop iterating sp_two_raw_file

    end ##end of outer for loop iterating sp_one_raw_file

    sp_one_rows.each do |sp_one_line|
      if not compared_metrics.include? sp_one_line[0]
        unmatched_metrics.push(sp_one_line[0])
      end
    end

    sp_two_rows.each do |sp_two_line|
      if not compared_metrics.include? sp_two_line[0]
        unmatched_metrics.push(sp_two_line[0])
      end
    end

    result[:compared_metrics] = compared_metrics
    result[:std_dev] = std_dev
    result[:max_dev] = max_dev
    result[:total_data_pt] = total_data_pt

    if need_all_data
      result[:unmatched_metrics] = unmatched_metrics
      result[:has_solid_data] = has_solid_data
      result[:has_same_time_series] = has_same_time_series
      result[:sp_one_raw_url] = sp_one_raw_url
      result[:sp_two_raw_url] = sp_two_raw_url
      result[:sp_one_data_series] = sp_one_data_series
      result[:sp_two_data_series] = sp_two_data_series
      result[:time_series] = time_series
    end

    result
  end


end ## end of class Graphiti
