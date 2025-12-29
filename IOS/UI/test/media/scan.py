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
    elif f.endswith('_img_Faz3.jpg'):
        try:
            poem_id = int(f.split('_')[0])
            ai_image.append(poem_id)
            print(f"  🖼️ Found: {f}")
        except ValueError:
            pass

# Sort lists
original_audio.sort()
ai_audio.sort()
ai_image.sort()

# Create media.json
media_data = {
    'original_audio': original_audio,
    'ai_audio': ai_audio,
    'ai_image': ai_image
}

output_path = os.path.join(current_dir, 'media.json')
with open(output_path, 'w', encoding='utf-8') as f:
    json.dump(media_data, f, indent=2, ensure_ascii=False)

print(f"\n✅ media.json created at: {output_path}")
print(f"\n📊 Summary:")
print(f"   🎤 Original Audio: {len(original_audio)} files")
print(f"   🤖 AI Audio: {len(ai_audio)} files")
print(f"   🖼️ AI Images: {len(ai_image)} files")

if len(original_audio) == 0 and len(ai_audio) == 0 and len(ai_image) == 0:
    print("\n⚠️ No media files found! Make sure files are named like:")
    print("   - 322.mp3")
    print("   - 340_AI_Faz3.mp3")
    print("   - 224_img_Faz3.jpg")