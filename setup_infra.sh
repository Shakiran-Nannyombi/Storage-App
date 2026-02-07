#!/bin/bash

# Configuration
PROJECT_ID=$(gcloud config get-value project)
REGION="us-central1"
BUCKET_NAME="${PROJECT_ID}-doc-upload"
TOPIC_NAME="doc-upload-topic"
SERVICE_NAME="doc-processor"
BQ_DATASET="doc_processing"
BQ_TABLE="metadata"
INVOKER_SA_NAME="pubsub-invoker"
INVOKER_SA_EMAIL="${INVOKER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "Using Project: $PROJECT_ID"
echo "Region: $REGION"

# Enable APIs
echo "Enabling APIs..."
gcloud services enable \
  artifactregistry.googleapis.com \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  pubsub.googleapis.com \
  storage.googleapis.com \
  bigquery.googleapis.com

# Create GCS Bucket
echo "Creating GCS Bucket..."
if ! gsutil ls -b gs://$BUCKET_NAME > /dev/null 2>&1; then
  gsutil mb -l $REGION gs://$BUCKET_NAME
else
  echo "Bucket $BUCKET_NAME already exists."
fi

# Create BigQuery Dataset and Table
echo "Creating BigQuery Dataset and Table..."
if ! bq ls --dataset_id=$BQ_DATASET > /dev/null 2>&1; then
  bq --location=$REGION mk --dataset $BQ_DATASET
else
  echo "Dataset $BQ_DATASET already exists."
fi

# Create Table Schema
# Schema: filename:STRING, upload_timestamp:TIMESTAMP, word_count:INTEGER, content_snippet:STRING, tags:STRING (repeated not supported easily in inline schema, using JSON or creating mostly unstructured for now, let's keep it simple)
# Actually, for "tags" as a list, we need a schema file or precise definition.
# Let's simplify and use CLI schema definition.
if ! bq show $BQ_DATASET.$BQ_TABLE > /dev/null 2>&1; then
  bq mk --table $BQ_DATASET.$BQ_TABLE \
    filename:STRING,upload_timestamp:TIMESTAMP,word_count:INTEGER,content_snippet:STRING,tags:STRING
else
  echo "Table $BQ_DATASET.$BQ_TABLE already exists."
fi

# Deploy Cloud Run Service
echo "Deploying Cloud Run Service..."
# Build image first
gcloud builds submit --tag gcr.io/$PROJECT_ID/$SERVICE_NAME

# Deploy
gcloud run deploy $SERVICE_NAME \
  --image gcr.io/$PROJECT_ID/$SERVICE_NAME \
  --platform managed \
  --region $REGION \
  --allow-unauthenticated \
  --set-env-vars BQ_DATASET=$BQ_DATASET,BQ_TABLE=$BQ_TABLE

# Get Service URL
SERVICE_URL=$(gcloud run services describe $SERVICE_NAME --platform managed --region $REGION --format 'value(status.url)')
echo "Service URL: $SERVICE_URL"

# Create Service Account for Pub/Sub to invoke Cloud Run
echo "Creating Service Account for Pub/Sub..."
if ! gcloud iam service-accounts describe $INVOKER_SA_EMAIL > /dev/null 2>&1; then
  gcloud iam service-accounts create $INVOKER_SA_NAME --display-name "Pub/Sub Invoker"
fi

# Give invoker role to the SA
gcloud run services add-iam-policy-binding $SERVICE_NAME \
  --member=serviceAccount:$INVOKER_SA_EMAIL \
  --role=roles/run.invoker \
  --region=$REGION \
  --platform=managed

# Create Pub/Sub Topic
echo "Creating Pub/Sub Topic..."
if ! gcloud pubsub topics describe $TOPIC_NAME > /dev/null 2>&1; then
  gcloud pubsub topics create $TOPIC_NAME
else
  echo "Topic $TOPIC_NAME already exists."
fi

# Create Pub/Sub Subscription (Push to Cloud Run)
echo "Creating Pub/Sub Subscription..."
SUBSCRIPTION_NAME="${TOPIC_NAME}-sub"
if ! gcloud pubsub subscriptions describe $SUBSCRIPTION_NAME > /dev/null 2>&1; then
  gcloud pubsub subscriptions create $SUBSCRIPTION_NAME \
    --topic $TOPIC_NAME \
    --push-endpoint=$SERVICE_URL \
    --push-auth-service-account=$INVOKER_SA_EMAIL
else
  echo "Subscription $SUBSCRIPTION_NAME already exists. Updating endpoint..."
  gcloud pubsub subscriptions update $SUBSCRIPTION_NAME \
    --push-endpoint=$SERVICE_URL \
    --push-auth-service-account=$INVOKER_SA_EMAIL
fi

# Configure GCS Notifications
echo "Configuring GCS Notifications..."
# Check if notification exists (simplified check, might duplicate if run multiple times without checking exact config)
# Ideally list notifications and check.
# For now, we assume if we run it, we want to ensure it's there.
# gsutil notification list gs://$BUCKET_NAME
# To be safe, we can try to create and ignore "exists" error or just clear and recreate?
# Let's just try to create.
gsutil notification create -t $TOPIC_NAME -f json gs://$BUCKET_NAME

echo "Setup Complete!"
echo "Upload a file to gs://$BUCKET_NAME to test."
