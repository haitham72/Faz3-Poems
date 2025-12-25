from flask import Flask, request, jsonify, send_file
import psycopg2
import psycopg2.extras

app = Flask(__name__)

@app.route('/')
def index():
    return send_file('../01_exact_match.html')

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
    limit = data.get('limit', 10)
    
    if not query:
        return jsonify({'error': 'Query required'}), 400
    
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        
        cur.execute("""
            SELECT * FROM hybrid_search_v1_core(%s, %s)
        """, (query, limit))
        
        results = cur.fetchall()
        
        cur.close()
        conn.close()
        
        return jsonify({'results': results, 'count': len(results)})
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    app.run(debug=True, port=5000)