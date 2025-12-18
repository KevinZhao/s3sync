import json
import os
import urllib.parse
import boto3
from botocore.exceptions import ClientError

s3_client = boto3.client('s3')

EXPRESS_BUCKET = os.environ['EXPRESS_BUCKET']
INGEST_PREFIX = os.environ['INGEST_PREFIX']

def lambda_handler(event, context):
    """
    Lambda function to sync objects from S3 Standard to S3 Express One Zone
    Triggered by S3 ObjectCreated events
    """

    print(f"Event: {json.dumps(event)}")

    for record in event['Records']:
        # Get source bucket and key from S3 event
        src_bucket = record['s3']['bucket']['name']
        src_key = urllib.parse.unquote_plus(record['s3']['object']['key'])

        # Skip if object is a directory marker
        if src_key.endswith('/'):
            print(f"Skipping directory marker: {src_key}")
            continue

        # Construct destination key
        # Remove any leading prefix and add ingest prefix
        filename = src_key.split('/')[-1]
        dst_key = f"{INGEST_PREFIX}{filename}"

        print(f"Syncing: s3://{src_bucket}/{src_key} -> s3://{EXPRESS_BUCKET}/{dst_key}")

        try:
            # Create S3 Express session
            print(f"Creating S3 Express session for bucket: {EXPRESS_BUCKET}")
            session_response = s3_client.create_session(
                Bucket=EXPRESS_BUCKET
            )
            print(f"Session created: {session_response['Credentials']['SessionToken'][:20]}...")

            # Copy object from standard bucket to Express directory bucket
            copy_source = {
                'Bucket': src_bucket,
                'Key': src_key
            }

            # Get object metadata
            head_response = s3_client.head_object(
                Bucket=src_bucket,
                Key=src_key
            )

            # Copy with metadata
            s3_client.copy_object(
                CopySource=copy_source,
                Bucket=EXPRESS_BUCKET,
                Key=dst_key,
                MetadataDirective='COPY',
                ContentType=head_response.get('ContentType', 'application/octet-stream')
            )

            print(f"Successfully copied to Express bucket: {dst_key}")

            # Optional: Get object size for logging
            object_size = head_response['ContentLength']
            print(f"Object size: {object_size} bytes")

        except ClientError as e:
            error_code = e.response['Error']['Code']
            error_message = e.response['Error']['Message']
            print(f"Error syncing object: {error_code} - {error_message}")

            if error_code == 'NoSuchBucket':
                print(f"Express bucket does not exist: {EXPRESS_BUCKET}")
            elif error_code == 'AccessDenied':
                print(f"Access denied. Check IAM permissions for Lambda role.")

            raise e

        except Exception as e:
            print(f"Unexpected error: {str(e)}")
            raise e

    return {
        'statusCode': 200,
        'body': json.dumps(f'Successfully processed {len(event["Records"])} records')
    }
