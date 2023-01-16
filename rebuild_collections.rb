require './zenfolio_api.rb'
require 'etc'
require 'fileutils'
require 'open-uri'

def get_or_make_collection( hiera, name, parent_tree, token )
  parent = hiera.dig(*parent_tree)

  if parent[name]
    return parent[name]
  else
    new_photoset = api_call( 'CreatePhotoSet', [ parent[:id], 'Collection', [name, '', [], [], ''] ], token )
    puts "Created new collection: #{new_photoset.inspect}"
    return new_photoset['Id']
  end
end

def filter_photo_ids_by_keywords_all(all_photo_details, photo_ids, keywords_all)
  return photo_ids.select do |pid|
    # Example of how this works:
    #
    # irb(main):001:0> [:a, :b] - [:a, :b, :c]
    # => []
    # irb(main):002:0> [:a, :b] - [:a, :c]
    # => [:b]
    #
    (keywords_all - all_photo_details[pid]['Keywords']) == []
  end
end

def select_photoset_ids(hiera, parent_tree, regex_str)
  photosets = find_hiera_items(hiera.dig(*parent_tree), 'PhotoSet')
  regex = %r{.}
  if regex_str
    regex = %r{#{regex_str}}
  end

  photosets = photosets.select do |photoset|
    photoset[:title].match?(regex)
  end
  photosets.map { |x| x[:id] }
end

def update_collection_from_photo_ids( collection_id, photo_ids, photo_ids_by_photoset, token )
  puts "Total photo ids count: #{photo_ids.length}"

  collection_photo_ids = photo_ids_by_photoset[collection_id]
  puts "Collection photos count, before: #{collection_photo_ids.length}"

  to_add = photo_ids - collection_photo_ids
  # puts "Items in photoset but not collection: #{to_add}"
  to_remove = collection_photo_ids - photo_ids
  # puts "Items in collection but not photoset: #{to_remove}"

  if to_add.length > 0
    print "\n\nAdding #{to_add.length} Photos To Collection: "
    to_add.each do |item|
      api_call( 'CollectionAddPhoto', [ collection_id, item ], token )
      print "."
    end
  else
    puts "\nNo photos to add to the collection."
  end
  puts

  if to_remove.length > 0
    print "\n\nRemoving #{to_remove.length} Photos From Collection: "
    to_remove.each do |item|
      api_call( 'CollectionRemovePhoto', [ collection_id, item ], token )
      print "."
    end
  else
    puts "\nNo photos to remove from the collection."
  end
  puts
end

def reduce_photo_file( from, to )
  if from =~ %r{\.(mov|mp4|wmv|avi)\.tmp}i
    resreg=%r{\s*([0-9]{3,5})x([0-9]{3,5})\s*}
    resolution=%x{ffmpeg -i "#{from}" -f ffmetadata -  2>&1 | grep -P ' [0-9]{3,6}x[0-9]{3,6},? ' | sed -r 's/.* ([0-9]{3,5}x[0-9]{3,5}),? .*/\\1/'}.chomp
    if resolution !~ resreg
      puts "Bad resolution #{resolution} for file #{from}"
      exit 1
    end
    orig_x=x=resolution.gsub(resreg,'\1').to_i
    orig_y=y=resolution.gsub(resreg,'\2').to_i

    puts "\n\n***** Processing movie #{from}"

    while x > 800 or y > 800
      puts "res: x: #{x}, y: #{y}"

      x = x/2
      y = y/2
    end

    if x != orig_x
      puts "final res: x: #{x}, y: #{y} ; converting"

      FileUtils.rm_f to
      %x{ffmpeg -i "#{from}" -map_metadata 0 -acodec copy -s #{x}x#{y} -vsync 2 "#{to}"}
      timestamp=%x{ffmpeg -i "#{to}"  -f ffmetadata - 2>&1 | grep '^  *creation_time  *:  *' | head -n 1}.chomp.gsub(%r{.*  *:  *},'')
      puts %Q{touch -d "#{timestamp}" "#{to}"}
      puts %x{touch -d "#{timestamp}" "#{to}"}
    else
      FileUtils.cp from, to
    end
  elsif from =~ %r{\.(jpg|png|gif|tiff)\.tmp}i
    orig_x=x=%x{identify -format "%w" "#{from}"}.chomp.to_i
    orig_y=y=%x{identify -format "%h" "#{from}"}.chomp.to_i
    puts "\n\n***** Processing image #{from}"

    while x > 1200 or y > 1200
      puts "res: x: #{x}, y: #{y}"

      x = x/2
      y = y/2
    end

    if x != orig_x
      puts "final res: x: #{x}, y: #{y} ; converting"

      FileUtils.rm_f to
      puts %x{convert "#{from}" -resize "#{x}x#{y}>" "#{to}"}
      ["%[EXIF:DateTimeOriginal]", "%[EXIF:DateTime]", "%[EXIF:DateTimeDigitized]"].each do |timetype|
        # The gsub is because the date format seems to be crazy;
        # colons instead of dashes.
        timestamp=%x{identify -format "#{timetype}" "#{to}"}.chomp.gsub(%r{^([0-9][0-9][0-9][0-9]):([0-9][0-9]):([0-9][0-9]) },"\\1-\\2-\\3 ")
        if timestamp.length > 5
          puts %Q{touch -d "#{timestamp}" "#{to}"}
          puts %x{touch -d "#{timestamp}" "#{to}"}
          break
        end
      end
    else
      FileUtils.cp from, to
    end
  else
    puts "I DON'T KNOW IF THIS IS A MOVIE OR AN IMAGE: #{from}"
  end
end

def update_mobile_pics_from_photos( album_name, ppdir, photo_ids, all_photo_details)
  remote_files={}
  full_photos={}
  photo_ids.each do |pid|
    photo = all_photo_details[pid]
    remote_files[photo['FileName']] = photo['UploadedOn']['Value']
    full_photos[photo['FileName']] = photo
  end

  mdfn = "cache/#{album_name}.metadata"
  metadata={}
  if File.exists?(mdfn)
    metadata = YAML.load_file(mdfn)
  end

  puts "Metadata count: #{metadata.length}"

  album_dir="#{ppdir}/#{album_name}"

  FileUtils.mkdir_p album_dir

  local_files=Dir.glob("#{album_dir}/**").map { |x| File.basename(x) }

  puts "Local file count: #{local_files.length}"

  # Find files to remove
  local_files.each do |lf|
    unless remote_files[lf]
      puts "\n\n*************** REMOVING #{lf}, since it is no longer starred."
      metadata.delete(lf)
      FileUtils.rm "#{album_dir}/#{lf}"

      File.open(mdfn, 'w') { |f| f.write(YAML.dump(metadata)) }
    end
  end

  # Find files to add
  remote_files.keys.each do |rf|
    metadata[rf] ||= 0
    rftime=DateTime.parse(remote_files[rf]).to_time.to_i
    unless local_files.include?(rf) and metadata[rf] >= rftime
      if ! local_files.include?(rf)
        puts "File #{rf} is not in list of local files."
      end
      if metadata[rf] < rftime
        puts "File #{rf} has stored time #{metadata[rf]} which is less then zenfolio time #{rftime}."
      end
      temp_file="/tmp/#{rf}.tmp"
      final_file="#{album_dir}/#{rf}"

      metadata[rf] = rftime
      puts "Downloading #{rf} to #{temp_file}"
      open(temp_file, 'wb') do |file|
        file << URI.open(full_photos[rf]['OriginalUrl']).read
      end

      reduce_photo_file( temp_file, final_file )

      File.open(mdfn, 'w') { |f| f.write(YAML.dump(metadata)) }

      FileUtils.rm_f temp_file

      if ! File.exists?(final_file)
        puts "\n\n**** CAN'T SEE #{final_file}!  Deleting metadata for it so a rerun will retry."
        metadata.delete(filename)
        File.open(mdfn, 'w') { |f| f.write(YAML.dump(metadata)) }
        exit 1
      end
    end
  end
end

config = YAML.load_file("zf_config.yaml")

token = login(config)

hiera, photosets_by_id, photo_ids_by_photoset_id, all_photo_details = get_zf_info(token)

config['collections'].each do |conf_collection|
  collection = get_or_make_collection( hiera, conf_collection['name'], conf_collection['parent_tree'], token )

  puts "\n\n********************************* Building collection #{collection[:title]}\n"

  if ! conf_collection['photosets']
    puts "Every collection must have a photosets entry with a parent_tree entry under it, to list out the photosets to draw pictures from."
  end

  photoset_ids = conf_collection['photosets'].map do |conf_photoset|
    select_photoset_ids(hiera, conf_photoset['parent_tree'], conf_photoset['regex'])
  end.flatten()

  photo_ids = photoset_ids.map { |psid| photo_ids_by_photoset_id[psid] }.flatten()

  puts "Photos from photosets count: #{photo_ids.count()}"

  if conf_collection['photos']
    photo_ids = conf_collection['photos'].map do |conf_photos|
      # Moybe TODO: add a 'keywords_any' that finds photos with *any*
      # of the keywords
      filter_photo_ids_by_keywords_all(all_photo_details, photo_ids, conf_photos['keywords_all'])
    end.flatten()
  end

  puts "Photos after filtering count: #{photo_ids.count()}"

  update_collection_from_photo_ids(collection[:id], photo_ids, photo_ids_by_photoset_id, token)

  # Here's where we save reduced-size copies of the photos, intended
  # to be synced to a phone for showing people
  if conf_collection['portable_photos']
    puts "\n\n******************* Dumping reduced size (portable) photos\n"

    if conf_collection['portable_photos']['keywords_all']
      photo_ids = filter_photo_ids_by_keywords_all(all_photo_details, photo_ids, conf_collection['portable_photos']['keywords_all'])
    end

    puts "Photos after filtering for portable dump count: #{photo_ids.count()}"

    update_mobile_pics_from_photos( conf_collection['portable_photos']['name'], config['portabble_photos_dir'], photo_ids, all_photo_details)
  end
end

config['photoset_cleanup'].each do |photoset_cleanup|
  if photoset_cleanup['reorder']
    puts "\n\n********************************* Reordering all photosets under #{photoset_cleanup['parent_tree'].inspect} with ordering #{photoset_cleanup['reorder']}"
    psids = find_hiera_ids(hiera.dig(*photoset_cleanup['parent_tree']), 'PhotoSet')
    Parallel.map(psids, in_threads: Etc.nprocessors * 4) do |photoset_id|
      print "#{photosets_by_id[photoset_id]['Title']}, "
      api_call( 'ReorderPhotoSet', [ photoset_id, photoset_cleanup['reorder'] ], token )
    end
    puts
  end
end
