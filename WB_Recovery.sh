#!/bin/bash

# Prompt user for the target URL
echo "Enter the base URL to search on Wayback Machine (e.g., example.com):"
read base_url

# Download list of URLs from the Wayback Machine with wildcard
echo "Fetching URLs from Wayback Machine..."
curl -s -G "http://web.archive.org/cdx/search/cdx" \
    --data-urlencode "url=${base_url}/*" \
    --data-urlencode "collapse=urlkey" \
    --data-urlencode "output=text" \
    --data-urlencode "fl=original,timestamp" | \
    sed 's/:80\//\//g' | \
    sed 's/:80$//g' > out.txt

# Check if out.txt has content
if [ ! -s out.txt ]; then
    echo "No URLs were retrieved from Wayback Machine. Check if the base URL is correct."
    exit 1
fi

# Extract URLs with specific file extensions and clean them
echo "Filtering for document files..."
grep -E '\.xls|\.xml|\.xlsx|\.json|\.pdf|\.sql|\.doc|\.docx|\.pptx|\.txt|\.zip|\.tar|\.gz|\.tgz|\.bak|\.7z|\.rar|\.log|\.cache|\.secret|\.db|\.backup|\.yml|\.gz|\.yaml|\.md|\.md5|\.exe|\.dll|\.bin|\.ini|\.bat|\.sh|\.deb|\.rpm|\.iso|\.img|\.apk|\.msi|\.dmg|\.tmp|\.crt|\.asc|\.key|\.pub|\.asc|\.config|\.csv' out.txt | \
    sort | \
    uniq > file_urls.txt

# Check if any matching files were found
if [ ! -s file_urls.txt ]; then
    echo "No matching document files found."
    exit 1
fi

# Create a directory to store downloaded files
mkdir -p "recovered_files/$base_url"

# Function to handle file decompression and conversion
handle_downloaded_file() {
    local input_file="$1"
    local output_file="$2"
    local file_type="$3"
    
    # Create a temporary file for processing
    local temp_file=$(mktemp)
    
    # Check if file is gzip compressed
    if [ "$(head -c 2 "$input_file" | xxd -p)" = "1f8b" ]; then
        echo "Detected gzip compression, decompressing..."
        gzip -cd "$input_file" > "$temp_file" 2>/dev/null || cp "$input_file" "$temp_file"
    else
        cp "$input_file" "$temp_file"
    fi
    
    # For text files, handle encoding
    if [[ "$file_type" == "text" ]]; then
        # Try to detect the encoding
        local encoding=$(file -i "$temp_file" | grep -o "charset=.*" | cut -d= -f2)
        
        # Convert to UTF-8, handling common encodings
        if [[ "$encoding" != "binary" ]]; then
            iconv -f "${encoding:-ISO-8859-1}" -t UTF-8//IGNORE < "$temp_file" > "$output_file" 2>/dev/null || \
            iconv -f CP1252 -t UTF-8//IGNORE < "$temp_file" > "$output_file" 2>/dev/null || \
            cp "$temp_file" "$output_file"
        else
            cp "$temp_file" "$output_file"
        fi
    else
        # For non-text files, just copy
        cp "$temp_file" "$output_file"
    fi
    
    # Clean up temp file
    rm "$temp_file"
}

# Initialize a counter for found files
found_files=0
recovered_files=0

# Check each file's availability and attempt recovery if necessary
while IFS=' ' read -r url timestamp; do
    filename=$(basename "$url")
    echo "Processing: $url"
    
    # Check if the file returns a 404
    if ! curl --head --silent --fail "$url" > /dev/null 2>&1; then
        echo "File not available: $url"
        
        if [[ -n "$timestamp" ]]; then
            # Construct the proper Wayback Machine URL with _if suffix for original file
            wayback_file_url="http://web.archive.org/web/${timestamp}id_/${url}"
            echo "Attempting to download from Wayback Machine: $wayback_file_url"
            
            # Create a temporary file for initial download
            temp_download=$(mktemp)
            
            # Use -L flag to follow redirects and proper headers
            if curl -s -L \
                -H "Accept-Language: en-US,en;q=0.9" \
                -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36" \
                --compressed \
                -o "$temp_download" \
                "$wayback_file_url"; then
                
                # Check if the downloaded file is not empty and not an HTML file
                if [ -s "$temp_download" ] && ! grep -q "<!DOCTYPE HTML" "$temp_download"; then
                    # Determine file type
                    case "$filename" in
                        *.txt|*.xml|*.csv|*.log|*.conf|*.ini|robots.txt)
                            file_type="text"
                            ;;
                        *)
                            file_type="binary"
                            ;;
                    esac
                    
                    # Process the file
                    handle_downloaded_file "$temp_download" "recovered_files/$base_url/$filename" "$file_type"
                    
                    echo "Successfully recovered: $filename"
                    ((recovered_files++))
                else
                    echo "Downloaded file appears to be invalid, removing..."
                fi
            fi
            
            # Clean up temp download
            rm "$temp_download"
        else
            echo "No timestamp found for: $url"
        fi
    else
        echo "File is available: $url"
        ((found_files++))
    fi
done < file_urls.txt

echo "Process complete."
echo "Files currently available: $found_files"
echo "Files recovered from Wayback Machine: $recovered_files"
echo "Check recovered_files/$base_url directory for any recovered files."
