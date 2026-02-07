import pandas as pd
from playwright.sync_api import sync_playwright
import time
import random
import os

# --- CONFIG ---
CDP_URL = "http://localhost:9223"
BASE_URL = "https://www.wneen.com/songwriter/26"
OUTPUT_FILE = "wneen_complete_archive.csv"
CHECKPOINT_FILE = "scraper_checkpoint.csv"

# Anti-detection settings
DELAY_BETWEEN_PAGES = (3, 6)
DELAY_BETWEEN_DETAILS = (2, 5)
SAVE_EVERY_N_SONGS = 10

def random_delay(min_sec, max_sec):
    time.sleep(random.uniform(min_sec, max_sec))

def extract_poem(page):
    """Extract full poem text with line breaks preserved"""
    try:
        lyrics_container = page.query_selector(".lyrics-list")
        if not lyrics_container:
            return "N/A"
        
        children = lyrics_container.query_selector_all(":scope > *")
        poem_lines = []
        
        for child in children:
            class_name = child.get_attribute("class") or ""
            
            if "lyrics-line" in class_name:
                line_text = child.inner_text().strip()
                if line_text:
                    poem_lines.append(line_text)
            elif "lyrics-break-line" in class_name:
                poem_lines.append("")
        
        poem_text = "\n".join(poem_lines)
        return poem_text if poem_text else "N/A"
        
    except Exception as e:
        return "N/A"

def extract_composer(page):
    """Extract composer (الملحن)"""
    try:
        h3_elements = page.query_selector_all("h3")
        
        for h3 in h3_elements:
            h3_text = h3.inner_text().strip()
            if "الملحن" in h3_text:
                composer_link = page.query_selector(f"xpath=//h3[contains(., 'الملحن')]/following-sibling::*//a")
                if composer_link:
                    return composer_link.inner_text().strip()
        
        return "N/A"
        
    except:
        return "N/A"

def load_checkpoint():
    if os.path.exists(CHECKPOINT_FILE):
        print(f"📂 Resuming from checkpoint...")
        df = pd.read_csv(CHECKPOINT_FILE, encoding='utf-8-sig')
        return df.to_dict('records')
    return []

def save_checkpoint(songs):
    df = pd.DataFrame(songs)
    df.to_csv(CHECKPOINT_FILE, index=False, encoding='utf-8-sig')
    print(f"  💾 Saved ({len(songs)} songs)")

def run_scraper():
    all_songs = load_checkpoint()
    start_from = len(all_songs)
    
    if start_from > 0:
        print(f"✅ Resuming from song #{start_from + 1}")
    else:
        print(f"🆕 Starting fresh")

    with sync_playwright() as p:
        print(f"🔗 Connecting to Chrome CDP...")
        
        try:
            browser = p.chromium.connect_over_cdp(CDP_URL)
            context = browser.contexts[0]
            page = context.pages[0] if context.pages else context.new_page()
        except Exception as e:
            print(f"❌ Failed to connect to CDP. Make sure Chrome is running with:")
            print(f"   chrome.exe --remote-debugging-port=9222")
            return

        # STEP 1: Gather list
        if start_from == 0:
            print("\n" + "="*60)
            print("STEP 1: Gathering song list (8 pages)")
            print("="*60)
            
            for page_num in range(1, 9):
                url = f"{BASE_URL}/{page_num}" if page_num > 1 else BASE_URL
                print(f"\n📄 Page {page_num}...")
                
                try:
                    # Use domcontentloaded instead of networkidle to avoid blocking
                    page.goto(url, wait_until="domcontentloaded", timeout=30000)
                    time.sleep(3)  # Let page fully load
                    
                    # Check if blocked
                    page.wait_for_selector(".works-list", timeout=10000)
                    
                except Exception as e:
                    print(f"  ⚠️ Page blocked or login required!")
                    print(f"  Go to Chrome CDP window and:")
                    print(f"  1. Navigate to: {url}")
                    print(f"  2. Log in if needed")
                    print(f"  3. Wait for song list to appear")
                    print(f"\n  Press Enter when ready...")
                    input()
                    
                    # Try again
                    page.wait_for_selector(".works-list", timeout=30000)

                items = page.query_selector_all(".works-list > div")
                print(f"  Found: {len(items)} songs")
                
                for item in items:
                    try:
                        title_el = item.query_selector("h3 a")
                        if not title_el: 
                            continue
                        
                        title = title_el.inner_text().strip()
                        link = title_el.get_attribute("href")
                        if not link.startswith('http'): 
                            link = "https://www.wneen.com" + link

                        divs = item.query_selector_all("xpath=./div")
                        singer = divs[0].inner_text().strip() if len(divs) > 0 else "N/A"
                        
                        date = "N/A"
                        if len(divs) >= 2:
                            date_span = divs[1].query_selector("span")
                            date = date_span.inner_text().strip() if date_span else "N/A"

                        all_songs.append({
                            'PageNumber': page_num,
                            'Title': title, 
                            'Singer': singer,
                            'Composer': 'N/A',
                            'Date': date, 
                            'DetailURL': link, 
                            'YouTube': 'N/A',
                            'Poem': 'N/A'
                        })
                    except: 
                        continue
                
                print(f"  Total: {len(all_songs)}")
                
                if page_num < 8:
                    delay = random.uniform(*DELAY_BETWEEN_PAGES)
                    print(f"  ⏳ {delay:.1f}s...")
                    time.sleep(delay)
            
            save_checkpoint(all_songs)

        # STEP 2: Extract details
        print("\n" + "="*60)
        print(f"STEP 2: Extracting details")
        print(f"Songs {start_from + 1} to {len(all_songs)}")
        print("="*60)

        for index in range(start_from, len(all_songs)):
            song = all_songs[index]
            
            try:
                print(f"\n[{index + 1}/{len(all_songs)}] P{song['PageNumber']} - {song['Title'][:45]}...")
                
                page.goto(song['DetailURL'], wait_until="domcontentloaded", timeout=15000)
                time.sleep(1)
                
                # YouTube
                yt_element = page.query_selector("lite-yt")
                if yt_element:
                    vid_id = yt_element.get_attribute("video")
                    if vid_id:
                        song['YouTube'] = f"https://www.youtube.com/watch?v={vid_id}"
                        print(f"  ✓ YT: {vid_id}")
                
                # Composer
                composer = extract_composer(page)
                song['Composer'] = composer
                if composer != "N/A":
                    print(f"  ✓ Composer: {composer[:30]}")
                
                # Poem
                poem = extract_poem(page)
                song['Poem'] = poem
                if poem != "N/A":
                    preview = poem.split('\n')[0][:35]
                    print(f"  ✓ Poem: {preview}...")
                
            except Exception as e:
                print(f"  ❌ {e}")
                continue
            
            if (index + 1) % SAVE_EVERY_N_SONGS == 0:
                save_checkpoint(all_songs)
            
            if index < len(all_songs) - 1:
                delay = random.uniform(*DELAY_BETWEEN_DETAILS)
                time.sleep(delay)

        # FINAL SAVE
        df = pd.DataFrame(all_songs)
        cols = ['PageNumber', 'Title', 'Singer', 'Composer', 'Date', 'YouTube', 'DetailURL', 'Poem']
        df = df[cols]
        df.to_csv(OUTPUT_FILE, index=False, encoding='utf-8-sig')
        
        if os.path.exists(CHECKPOINT_FILE):
            os.remove(CHECKPOINT_FILE)
        
        print("\n" + "="*60)
        print(f"✅ DONE! {OUTPUT_FILE}")
        print("="*60)
        
        yt = sum(1 for s in all_songs if s['YouTube'] != 'N/A')
        comp = sum(1 for s in all_songs if s['Composer'] != 'N/A')
        poem = sum(1 for s in all_songs if s['Poem'] != 'N/A')
        
        print(f"\n📊 Results:")
        print(f"   Songs: {len(all_songs)}")
        print(f"   YouTube: {yt} ({yt/len(all_songs)*100:.0f}%)")
        print(f"   Composer: {comp} ({comp/len(all_songs)*100:.0f}%)")
        print(f"   Poems: {poem} ({poem/len(all_songs)*100:.0f}%)")

if __name__ == "__main__":
    run_scraper()