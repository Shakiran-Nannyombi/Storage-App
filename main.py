import base64
import json
import os
import logging
from flask import Flask, request
from google.cloud import storage
from google.cloud import bigquery
from datetime import datetime

app = Flask(__name__)

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Initialize clients
storage_client = storage.Client()
bq_client = bigquery.Client()

# Environment variables
BQ_DATASET = os.environ.get('BQ_DATASET', 'doc_processing')
BQ_TABLE = os.environ.get('BQ_TABLE', 'metadata')

@app.route("/", methods=["POST"])
def index():
    """Receive and process Pub/Sub messages."""
    envelope = request.get_json()
    if not envelope:
        msg = "no Pub/Sub message received"
        print(f"error: {msg}")
        return f"Bad Request: {msg}", 400

    if not isinstance(envelope, dict) or "message" not in envelope:
        msg = "invalid Pub/Sub message format"
        print(f"error: {msg}")
        return f"Bad Request: {msg}", 400

    pubsub_message = envelope["message"]

    if isinstance(pubsub_message, dict) and "data" in pubsub_message:
        try:
            data = base64.b64decode(pubsub_message["data"]).decode("utf-8").strip()
            # The message data from GCS notification is a JSON string
            event_data = json.loads(data)
            
            # Extract bucket and file name
            bucket_name = event_data.get('bucket')
            file_name = event_data.get('name')
            
            if not bucket_name or not file_name:
                logger.warning("Bucket or filename missing in event data.")
                return "OK", 200

            logger.info(f"Processing file: {file_name} from bucket: {bucket_name}")
            
            process_file(bucket_name, file_name)

        except Exception as e:
            logger.error(f"Error processing message: {e}")
            return f"Error: {e}", 500

    return "OK", 200

def process_file(bucket_name, file_name):
    """Downloads file, performs simulated OCR, and streams metadata to BigQuery."""
    try:
        bucket = storage_client.bucket(bucket_name)
        blob = bucket.blob(file_name)
        
        # Download content
        content = blob.download_as_text()
        
        # Simulated OCR: Count words
        word_count = len(content.split())
        
        # Metadata extraction
        metadata = {
            "filename": file_name,
            "upload_timestamp": datetime.utcnow().isoformat(),
            "word_count": word_count,
            "content_snippet": content[:100] if len(content) > 100 else content,
            "tags": ["simulated", "ocr", "processed"] # Example tags
        }
        
        logger.info(f"Extracted metadata: {metadata}")
        
        # Stream to BigQuery
        insert_into_bigquery(metadata)
        
    except Exception as e:
        logger.error(f"Failed to process file {file_name}: {e}")
        raise

def insert_into_bigquery(row):
    """Inserts a row into BigQuery."""
    table_id = f"{bq_client.project}.{BQ_DATASET}.{BQ_TABLE}"
    
    errors = bq_client.insert_rows_json(table_id, [row])
    
    if errors:
        logger.error(f"Encountered errors while inserting rows: {errors}")
        raise Exception(f"BigQuery insert failed: {errors}")
    
    logger.info("Successfully inserted row into BigQuery.")

if __name__ == "__main__":
    app.run(debug=True, host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
