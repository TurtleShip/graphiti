require 'pp'

class Graph
  include Redised

  def self.save(uuid = nil, graph_json)
    uuid ||= make_uuid(graph_json)
    redis.hset "graphs:#{uuid}", "title", graph_json[:title]
    redis.hset "graphs:#{uuid}", "json", graph_json[:json]
    redis.hset "graphs:#{uuid}", "updated_at", Time.now.to_i
    redis.hset "graphs:#{uuid}", "url", graph_json[:url]
    redis.zadd "graphs", Time.now.to_i, uuid
    uuid
  end

  def self.find(uuid)
    #pp redis
    h = redis.hgetall "graphs:#{uuid}"
    h['uuid']      = uuid
    h['snapshots'] = redis.zrange "graphs:#{uuid}:snapshots", 0, -1
    h
  rescue
    nil
  end

  def self.snapshot(uuid)
    puts "snapshotting graph"
    graph = find(uuid)
    return nil if !graph

    ## Grab a graph
    graph_url = graph['url'].gsub(/\#.*$/,'')

    # I know that 20 second timeout seems insane
    # But you might need it in case you are uploading an exremely large file
    graph_response = Typhoeus::Request.get(graph_url, :timeout => 20000)
    return false if !graph_response.success?
    graph_data = graph_response.body
    time = (Time.now.to_f * 1000).to_i
    graph_filename = "/snapshots/#{uuid}/image/#{time}.png"

	## Grab a csv file to send to S3 store
  #csv_url = graph['url'].gsub(/\#.*$/,'')
	#csv_url = csv_url[0..csv_url.index("&_timestamp")] + "format=csv"
   	
	#csv_response = Typhoeus::Request.get(csv_url, :timeout => 5000)
	#return false if !csv_response.success?
	#csv_data = csv_response.body

	# use the same timestamp as graph
	#csv_filename = "/snapshots/#{uuid}/csv/#{time}.csv"

    # grab a raw data
    raw_url = graph['url'].gsub(/\#.*$/,'')
    puts "raw_url : #{raw_url}"
    puts "index : #{raw_url.index("&_timestamp")}"
    raw_url = raw_url[0..raw_url.index("&_timestamp")] + "format=raw"

    raw_response = Typhoeus::Request.get(raw_url, :timeout => 20000)
    return false if !raw_response.success?
    raw_data = raw_response.body

    # use the same timestamp as graph
    raw_filename = "/snapshots/#{uuid}/raw/#{time}.csv"

    puts "Uploading graph and raw file\n"

	  # upload to S3 store here
    return false if !S3::Request.upload(graph_filename, StringIO.new(graph_data), 'image/png')
	  #return false if !S3::Request.upload(csv_filename, StringIO.new(csv_data), 'text/csv')
    return false if !S3::Request.upload(raw_filename, StringIO.new(raw_data), 'text/csv')

    puts "Upload success"

    graph_url = S3::Request.url(graph_filename)
    redis.zadd "graphs:#{uuid}:snapshots", time, graph_url

    #raw_url = S3::Request.url(raw_filename)
    #redis.zadd "graphs:#{uuid}:snapshots", time, raw_url

    graph_url
  end

  def self.dashboards(uuid)
    redis.smembers("graphs:#{uuid}:dashboards")
  end

  def self.destroy(uuid)
    redis.del "graphs:#{uuid}"
    redis.zrem "graphs", uuid
    self.dashboards(uuid).each do |dashboard|
      Dashboard.remove_graph dashboard, uuid
    end
  end

  def self.all(*graph_ids)
    graph_ids = redis.zrevrange "graphs", 0, -1 if graph_ids.empty?
    graph_ids ||= []
    graph_ids.flatten.collect do |uuid|
      find(uuid)
    end.compact
  end

  def self.make_uuid(graph_json)
    Digest::SHA1.hexdigest(graph_json.inspect + Time.now.to_f.to_s + rand(100).to_s)[0..10]
  end

end
