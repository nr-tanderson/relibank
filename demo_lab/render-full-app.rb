require "yaml"

manifest_path = ARGV.fetch(0)
manifest = File.read(manifest_path)
manifest = manifest.gsub("${REGISTRY_URL}", ENV.fetch("REGISTRY_URL"))
manifest = manifest.gsub("${IMAGE_TAG}", ENV.fetch("IMAGE_TAG"))
documents = YAML.load_stream(manifest).compact
jobs = documents.select { |document| document["kind"] == "Job" }

File.write(ENV.fetch("RESOURCES_FILE"), (documents - jobs).map(&:to_yaml).join)
jobs.each do |job|
  name = job.dig("metadata", "name")
  File.write(File.join(ENV.fetch("JOB_DIR"), "#{name}.yaml"), job.to_yaml)
end