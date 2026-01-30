from flask import Flask, request, jsonify, send_file
import psycopg2
import psycopg2.extras

app = Flask(__name__)

@app.route('/')
def index():
    return send_file('../05_exact_match.html')

DB_CONFIG = {
    'host': 'aws-1-ap-south-1.pooler.supabase.com',
    'database': 'postgres',
    'user': 'postgres.uffjlburuvsnstvgyito',
    'password': 'Iopiop@_72'
}

@app.route('/api/search', methods=['POST'])
def search():
    data = request.json
    query = data.get('query', '')
    limit = data.get('limit', 100)
    
    if not query:
        return jsonify({'error': 'Query required'}), 400
    
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        print(f"Query: {query}, Limit: {limit}")  # Before execute
        
        cur.execute("""
            SELECT * FROM hybrid_search_v1_core(%s, %s)
        """, (query, limit))
        
        results = cur.fetchall()

        print(f"Fetched rows: {len(results)}")    # After fetchall

        title_matches = sum(1 for r in results if 'title' in r['match_location'])
        poem_matches = sum(1 for r in results if 'poem_line' in r['match_location'])

        
        
        
        cur.close()
        conn.close()
        
        return jsonify({
            'results': results,
            'total_matches': len(results),
            'title_matches': title_matches,
            'poem_matches': poem_matches
        })
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    app.run(debug=True, port=5000)