#!/bin/bash
# ─────────────────────────────────────────────────────────────
# wildlearn Backend — Cloud Run Deploy Script
# Run this from inside the /backend folder:
#   chmod +x deploy.sh && ./deploy.sh
# ─────────────────────────────────────────────────────────────

PROJECT_ID="YOUR_PROJECT_ID"
SERVICE_NAME="wildlearn-backend"
REGION="us-central1"
IMAGE="gcr.io/$PROJECT_ID/$SERVICE_NAME"

echo "🌿 Building and deploying wildlearn backend to Cloud Run..."

# Build and push the container
gcloud builds submit --tag $IMAGE --project $PROJECT_ID

# Deploy to Cloud Run
gcloud run deploy $SERVICE_NAME \
  --image $IMAGE \
  --platform managed \
  --region $REGION \
  --allow-unauthenticated \
  --memory 2Gi \
  --timeout 600 \
  --project $PROJECT_ID

echo ""
echo "✅ Deployment complete!"
echo "Your backend URL will be shown above."
echo "Copy the URL and paste it into lib/config.dart in your Flutter app."
