Hosting on Google Cloud

•   Place your Gemini key in main.py file in backend folder
•   Place Google project ID in deploy.sh in backend folder
•   Host all the files in backend in Google cloud
•   Then place the Cloud Run backend URL in config.dart


Building an APK 

1. Setup the Project
•	Download or Clone this repository to your computer.
•	Open the folder in Android Studio or VS Code.

2. Install Dependencies
Open your terminal and type this command, then press Enter: flutter pub get

3. Add your API Key for species identification (Optional)
•	Go to the lib/ folder.
•	Put Gemini API key in upload_picture_page.dart

4. firestore 
Place your firestore credentials in main.dart to store sightings data for

apiKey: ""
appId: ""
messagingSenderId: ""
projectId: ""
storageBucket: ""

5. Run the App
•	Connect your Android phone or start an Emulator and run



