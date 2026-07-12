require "json"
require "date"
require "net/http"
require "uri"

SOURCE = "https://www.skysports.com/football/news/12098/13481245/world-cup-2026-fixture-schedule-and-uk-kick-off-times-day-by-day-breakdown-of-all-104-matches-including-england-scotland"

uri = URI(SOURCE)
request = Net::HTTP::Get.new(uri)
request["User-Agent"] = "Mozilla/5.0 (compatible; RetiredUnlimitedResultsBot/1.0)"
response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
abort "Results source returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

encoded = response.body.match(/"articleBody":\s*("(?:\\.|[^"\\])*")/m)&.[](1)
abort "Could not locate the results article" unless encoded
body = JSON.parse(encoded)

rows = body.scan(/<(h2|h3|li)[^>]*>(.*?)<\/\1>/m).map do |tag, html|
  text = html.gsub(/<[^>]+>/, " ").gsub(/&[a-z]+;/, " ").gsub(/\s+/, " ").strip
  [tag, text]
end

section = date = nil
matches = []

rows.each do |tag, text|
  if tag == "h2"
    section = text
    next
  elsif tag == "h3"
    date = Date.parse("#{text.delete(',')} 2026").strftime("%Y-%m-%d") rescue nil
    next
  end

  next unless tag == "li" && section && date
  next unless ["Remaining knockout schedule", "Last 16 results", "Last 32 results", "Group stage results"].include?(section)

  stage = case section
          when "Group stage results" then text[/Group [A-L]/]
          when "Last 32 results" then "Round of 32"
          when "Last 16 results" then "Round of 16"
          else text[/Quarter-final|Semi-final|Third Place Playoff|Final/]
          end
  next unless stage

  clean = text.sub(/^Group [A-L]:\s*/, "")
              .sub(/^Round of (?:16|32)\s*-\s*/, "")
              .sub(/^(?:Quarter-final|Semi-final|Third Place Playoff|Final)\s*-\s*/, "")
              .sub(/^Match \d+:\s*/, "")
  venue = clean.split(/\s+-\s+/).last
  match_text = clean.split(/\s+-\s+/).first.sub(/, kick-off.*$/, "")
  note = match_text[/\s+(\([^)]*\))$/, 1]
  match_text = match_text.sub(/\s+\([^)]*\)$/, "")

  if match_text =~ /\A(.+?)\s+(\d+)-(\d+)\s+(.+)\z/
    home, home_score, away_score, away = $1, $2.to_i, $3.to_i, $4
    status = "complete"
  elsif match_text =~ /\A(.+?)\s+vs\s+(.+)\z/
    home, away = $1, $2
    home_score = away_score = nil
    status = "upcoming"
  else
    next
  end

  aliases = {"Bosnia" => "Bosnia-Herzegovina", "Bosnia-Herzegovina" => "Bosnia-Herzegovina"}
  home = aliases.fetch(home, home)
  away = aliases.fetch(away, away)
  matches << {date: date, stage: stage, home: home, away: away, homeScore: home_score,
              awayScore: away_score, note: note&.delete_prefix("(")&.delete_suffix(")"),
              venue: venue, status: status}
end

abort "Expected 104 matches, found #{matches.length}" unless matches.length == 104
abort "Duplicate fixtures detected" unless matches.map { |m| [m[:date], m[:home], m[:away]] }.uniq.length == 104

updated = matches.select { |m| m[:status] == "complete" }.map { |m| m[:date] }.max
path = File.expand_path("../index.html", __dir__)
page = File.read(path)
old_complete = page.scan(/"status": "complete"/).length
new_complete = matches.count { |m| m[:status] == "complete" }
abort "Completed match count went backwards (#{old_complete} to #{new_complete})" if new_complete < old_complete

replacement = "window.MATCHES = #{JSON.pretty_generate(matches)};\nconst $ ="
updated_page = page.sub(/window\.DATA_UPDATED_AT = "[^"]+";/, "window.DATA_UPDATED_AT = #{updated.to_json};")
                   .sub(/window\.MATCHES = \[.*?\];\nconst \$ =/m, replacement)
abort "Could not update embedded match data" if updated_page == page && new_complete > old_complete

if updated_page == page
  puts "No new completed matches."
else
  File.write(path, updated_page)
  puts "Updated results: #{old_complete} → #{new_complete} completed matches (through #{updated})."
end
