import os
import json

# Get current directory
current_dir = os.getcwd()
print(f"📂 Scanning folder: {current_dir}")

# List all files in current directory
all_files = os.listdir('.')
print(f"📄 Total files found: {len(all_files)}")

# Filter media files
original_audio = []
ai_audio = []
ai_song = []
ai_song_dict = {}  # Store poem_id -> [list of filenames]
ai_image = []

for f in all_files:
    if f.endswith('.mp3') and '_' not in f:
        try:
            poem_id = int(f.replace('.mp3', ''))
            original_audio.append(poem_id)
            print(f"  🎤 Found: {f}")
        except ValueError:
            pass
    elif f.endswith('_AI_Faz3.mp3'):
        try:
            poem_id = int(f.split('_')[0])
            ai_audio.append(poem_id)
            print(f"  🤖 Found: {f}")
        except ValueError:
            pass
    elif '_AI_song' in f and f.endswith('.mp3'):
        try:
            # Handle both "5_AI_song.mp3" and "5_AI_song (1).mp3"
            poem_id = int(f.split('_')[0])
            
            # Extract variation number if exists
            if '(' in f and ')' in f:
                # "5_AI_song (2).mp3" -> variation 2
                variation = f.split('(')[1].split(')')[0]
                if poem_id not in ai_song_dict:
                    ai_song_dict[poem_id] = []
                ai_song_dict[poem_id].append(f)
                print(f"  🎵 Found: {f} (variation {variation})")
            else:
                # "5_AI_song.mp3" -> single file
                if poem_id not in ai_song_dict:
                    ai_song_dict[poem_id] = []
                ai_song_dict[poem_id].append(f)
                print(f"  🎵 Found: {f}")
        except (ValueError, IndexError):
            pass
    elif f.endswith('_img_Faz3.jpg'):
        try:
            poem_id = int(f.split('_')[0])
            ai_image.append(poem_id)
            print(f"  🖼️ Found: {f}")
        except ValueError:
            pass

# Convert ai_song_dict to list of poem_ids and store filenames
ai_song = sorted(list(ai_song_dict.keys()))

# Sort other lists
original_audio.sort()
ai_audio.sort()
ai_image.sort()

# Create media.json
media_data = {
    'original_audio': original_audio,
    'ai_audio': ai_audio,
    'ai_song': ai_song,
    'ai_song_files': ai_song_dict,  # Map of poem_id -> list of filenames
    'ai_image': ai_image
}

output_path = os.path.join(current_dir, 'media.json')
with open(output_path, 'w', encoding='utf-8') as f:
    json.dump(media_data, f, indent=2, ensure_ascii=False)

print(f"\n✅ media.json created at: {output_path}")
print(f"\n📊 Summary:")
print(f"   🎤 Original Audio: {len(original_audio)} files")
print(f"   🤖 AI Audio: {len(ai_audio)} files")
print(f"   🎵 AI Song: {len(ai_song)} poems ({sum(len(files) for files in ai_song_dict.values())} total files)")
print(f"   🖼️ AI Images: {len(ai_image)} files")

if len(original_audio) == 0 and len(ai_audio) == 0 and len(ai_song) == 0 and len(ai_image) == 0:
    print("\n⚠️ No media files found! Make sure files are named like:")
    print("   - 322.mp3")
    print("   - 340_AI_Faz3.mp3")
    print("   - 332_AI_song.mp3")
    print("   - 224_img_Faz3.jpg")
