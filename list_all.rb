require './zenfolio_api.rb'

config = YAML.load_file("zf_config.yaml")

token = login(config)

hiera = get_trimmed_hierarchy( token )
puts YAML.dump(hiera)
