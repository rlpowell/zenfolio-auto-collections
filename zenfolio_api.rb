require 'net/http'
require 'net/https'
require 'nokogiri'
require 'yaml'
require 'json'
require 'digest'
require 'parallel'

$id = 1

def api_call( method, params, token = nil )
  uri = URI('https://api.zenfolio.com/api/1.8/zfapi.asmx/AuthenticatePlain')
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.verify_mode = OpenSSL::SSL::VERIFY_NONE
  # http.ssl_version = :TLSv2
  # http.set_debug_output $stderr
  request = Net::HTTP::Post.new('/api/1.8/zfapi.asmx')
  request.body = JSON.dump({ 'method' => method, 'params' => params, 'id' => $id })
  $id += 1
  request['Content-Type'] = 'application/json'
  if token
    request['X-Zenfolio-Token'] = token
  end
  begin
    output=JSON.load(http.request(request).body)
  rescue JSON::ParserError => e
    puts "JSON error:"
    puts e
    puts e.backtrace
    puts http.request(request).body
    puts YAML.dump(request)
    exit 1
  rescue Net::OpenTimeout
    puts "Net open timeout; retrying"
    sleep 1
    retry
  rescue Net::ReadTimeout
    puts "Net read timeout; retrying"
    sleep 1
    retry
  end

  if output['error']
    puts "Error in method #{method}: #{output['error']}."
    puts "Request was: #{request.body.inspect}"
    puts "Output was: #{output.inspect}"
    raise StandardError
    exit 1
  else
    return output['result']
  end
end

# Gathere all the ids of a given type (if any) out of the hierarchy
# of stuff we colleced from the LoadGroupHierarchy call using
# get_trimmed_hierarchy
def find_hiera_ids( tree, type=nil )
  find_hiera_items(tree, type).map { |x| x[:id] }
end
def find_hiera_items( tree, type=nil )
  if tree.is_a?(Hash)
    rets=[]
    # Here we gather everything that matches the type asked for, if any
    if type
      if tree[:type] == type
        rets << tree
      end
    else
      rets << tree
    end
    # Any string key is a subtree; any symbol key is metadata (i.e. :id )
    subtree_keys = tree.keys.select { |x| x.is_a?(String) }
    rets += subtree_keys.map { |x| find_hiera_items( tree[x], type ) }.compact.flatten
    return rets
  else
    return nil
  end
end

def get_trimmed_hierarchy( token )
  root = api_call( 'LoadGroupHierarchy', [ 'rlpowell' ], token )
  hiera = trimmed_hierarchy(root)
  return hiera
end

def trimmed_hierarchy( tree )
  newtree = {}
  if tree.is_a?(Hash)
    if tree['Elements'].nil? || tree['Elements'].empty?
      tree['Id']
    else
      tree['Elements'].map do |x|
        newtree[x['Title']] = { :title => x['Title'], :id => x['Id'], :type => x['$type'] }
        sub = trimmed_hierarchy( x )
        sub.keys.each do |key|
          newtree[x['Title']][key] = sub[key]
        end
      end
    end
  end
  newtree
end

# photos = api_call( 'SearchPhotoByText', [ 0, 'Date', 'k_and_f', 0, 10000 ], token )
# puts "Search photos, before: "
# puts YAML.dump( photos )
# exit

def get_all_group_photosets( group, token )
  photosets = []
  group_members = api_call( 'LoadGroup', [ group, 'Level1', true ], token )
  group_members['Elements'].each do |elem|
    # puts elem['$type']
    if elem['$type'] == 'PhotoSet'
      photosets << elem['Id']
    elsif elem['$type'] == 'Group'
      photosets << get_all_group_photosets( elem['Id'], token )
      photosets = photosets.flatten
    end
  end

  return photosets
end

def login(config)
  # Auth flow is described at https://www.zenfolio.com/zf/help/api/guide/auth/auth-challenge
  #
  # I'm quite startled that I didn't run into any weird encoding
  # issues here :D
  challenge = api_call( 'GetChallenge', [config['email']])
  digest = Digest::SHA256.digest (challenge['PasswordSalt'].pack('c*') + config['password'])
  digest2 = Digest::SHA256.digest (challenge['Challenge'].pack('c*') + digest)

  return api_call( 'Authenticate', [challenge['Challenge'], digest2.bytes()] )
end

def get_zf_info(token)
  puts "Getting the group hierarchy info"
  hiera = get_trimmed_hierarchy( token )

  # We use Etc.nprocessors * 4 for parallelism here becuase I assume
  # that the vast majority of the time is spent waiting for the API
  # call to return

  puts "Getting basic info on all the photosets"
  # puts YAML.dump(hiera)
  # photoset_photos = Concurrent::Map.new()
  photoset_ids = find_hiera_ids(hiera, 'PhotoSet')
  photosets_by_id = Parallel.map(photoset_ids, in_threads: Etc.nprocessors * 4) do |photoset_id|
    # puts "pid: #{photoset_id}"
    photoset = api_call( 'LoadPhotoSet', [ photoset_id, 'Level1', true ], token )
    puts "Photoset #{photoset['Title']} / #{photoset['Id']} photo count: #{photoset['Photos'].length}"
    [photoset_id, photoset]
  end
  photosets_by_id = photosets_by_id.to_h()

  # Pull out just the photo ids, as this comes up repeatedly
  photo_ids_by_photoset_id = {}
  photosets_by_id.keys.each do |photoset_id|
    photo_ids_by_photoset_id[photoset_id] = photosets_by_id[photoset_id]['Photos'].map { |x| x['Id'] }
  end

  puts "\n\nPhotoset count (includes collections): #{photo_ids_by_photoset_id.keys().count()}"
  all_photo_ids = photo_ids_by_photoset_id.values().flatten().uniq()
  puts "Photo count: #{all_photo_ids.count()}"

  puts "Getting details on all the photos; this'll take a bit"
  all_photo_details = Parallel.map(all_photo_ids, in_threads: Etc.nprocessors * 4) do |pid|
    # photo = api_call( 'LoadPhoto', [ pid, 'Full' ], token )
    print "."
    # photo['Keywords'].include?('rlp_favorites')
    [pid, api_call( 'LoadPhoto', [ pid, 'Full' ], token )]
  end
  puts
  all_photo_details = all_photo_details.to_h()
  puts "Photo details count: #{all_photo_details.count()}"
  # puts YAML.dump(all_photo_details)

  return hiera, photosets_by_id, photo_ids_by_photoset_id, all_photo_details
end

