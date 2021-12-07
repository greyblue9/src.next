# Build APKs for Kiwi Browser Next
name: 'Kiwi: Build and sign release apk'

# Controls when the action will run. Triggers the workflow on push or pull request events
on:
  workflow_dispatch:
    inputs:
      prepareRelease:
        description: 'Create a draft release in Google Play Store'     
        required: true
        default: 'no'
      announceOnDiscord:
        description: 'Announce new release on Discord channel'     
        required: true
        default: 'yes'

# A workflow run is made up of one or more jobs that can run sequentially or in parallel
jobs:
  build:
    # The type of runner that the job will run on
    runs-on: ubuntu-latest

    strategy:
      fail-fast: false
      max-parallel: 4
      matrix:
        platform: [arm, arm64, x86, x64]
    steps:
      - name: Initializing build
        run: echo Initializing build for platform ${{ matrix.platform }}

      - name: Updating APT repository
        run: sudo apt-get update

      - name: Installing rclone
        run: curl https://rclone.org/install.sh | sudo bash
  
      - name: set up dirs
        continue-on-error: true
        run: mkdir -p ~/.config/rclone/; echo $'[cache]\ntype = cache\nupstreams = /tmp/.cache\n' | tee ~/.config/rclone/rclone.conf; mkdir -p /tmp/.cache; mkdir -p secondary_disk/out; rm -rf secondary_disk/out/*; ln -sf ../../.build/production_build_reference secondary_disk/out/android_arm64;

      - name: Installing Python and OpenJDK
        continue-on-error: true
        run: sudo apt-get install -y python openjdk-8-jdk-headless libncurses5 ccache

      - name: Reclaiming disk space on / by disabling swap partition
        continue-on-error: true
        run: |
          sudo swapoff -av
          sudo rm -f /swapfile

      - name: Reclaiming disk space on / by removing .NET framework
        continue-on-error: true
        run: sudo rm -rf /usr/share/dotnet

      # or alternatively, to work on the main partition
      - name: On HDD - Creating symlink on /dev/disk/azure/root-part1 pointing to /dev/disk/azure/resource-part1
        continue-on-error: true
       run: |
         sudo ln -s /extended_data /mnt/secondary_disk
         sudo ln -s /mnt/secondary_disk $GITHUB_WORKSPACE/

      # We cannot checkout outside of $GITHUB_WORKSPACE, but we want to checkout to the SSD

      - name: Creating output folder
        continue-on-error: true
        run: mkdir -p secondary_disk/out/android_${{ matrix.platform }}

      - name: Generating one-time APK signature key
        continue-on-error: true
        run: keytool -genkey -v -keystore keystore.jks -alias dev -keyalg RSA -keysize 2048 -validity 10000 -storepass public_password -keypass public_password -dname "cn=Kiwi Browser (unverified), ou=Actions, o=Kiwi Browser, c=GitHub"

      - name: Copying args.gn to target folder
        continue-on-error: true
        run: cat .build/android_arm/args.gn | sed "s#target_cpu = \"arm\"#target_cpu = \"${{ matrix.platform }}\"#" | sed "s#android_default_version_name = \"Git\"#android_default_version_name = \"Git$(date '+%y%m%d')Gen${{ github.run_id }}\"#" > secondary_disk/out/android_${{ matrix.platform }}/args.gn

      - name: Creating rclone config
        continue-on-error: true
        run: |
          mkdir -p $HOME/.config/rclone/
          echo '[cache]' > $HOME/.config/rclone/rclone.conf
          echo 'type = sftp' >> $HOME/.config/rclone/rclone.conf
          echo 'host = ${{ secrets.STORAGE_HOST }}' >> $HOME/.config/rclone/rclone.conf
          echo 'user = storage' >> $HOME/.config/rclone/rclone.conf
          echo 'key_pem = ${{ secrets.STORAGE_KEY }}' >> $HOME/.config/rclone/rclone.conf

      - name: Modifying args.gn (arm)
        continue-on-error: true
        if: matrix.platform == 'arm'
        run: sed -i "s#android_default_version_code = \"1\"#android_default_version_code = \"$(date '+%y%m%d')1\"#" secondary_disk/out/android_${{ matrix.platform }}/args.gn

      - name: Modifying args.gn (arm64)
        continue-on-error: true
        if: matrix.platform == 'arm64'
        run: sed -i "s#android_default_version_code = \"1\"#android_default_version_code = \"$(date '+%y%m%d')2\"#" secondary_disk/out/android_${{ matrix.platform }}/args.gn

      - name: Modifying args.gn (x86)
        continue-on-error: true
        if: matrix.platform == 'x86'
        run: sed -i "s#android_default_version_code = \"1\"#android_default_version_code = \"$(date '+%y%m%d')3\"#" secondary_disk/out/android_${{ matrix.platform }}/args.gn

      - name: Modifying args.gn (x64)
        continue-on-error: true
        if: matrix.platform == 'x64'
        run: sed -i "s#android_default_version_code = \"1\"#android_default_version_code = \"$(date '+%y%m%d')4\"#" secondary_disk/out/android_${{ matrix.platform }}/args.gn

      - name: Displaying args.gn
        continue-on-error: true
        run: cat secondary_disk/out/android_${{ matrix.platform }}/args.gn

      - name: Checking available disk-space
        continue-on-error: true
        run: df -h

      - name: Uploading args.gn
        continue-on-error: true
        run: rclone copy --fast-list --transfers=128 --retries=10 secondary_disk/out/android_${{ matrix.platform }}/args.gn cache:kiwibrowser-next-builds-${{ matrix.platform }}/

      - name: Calling buildbot
        continue-on-error: true
        if: false
        run: curl ipinfo.io

      - name: Downloading binary objects cache to $HOME/cache
        continue-on-error: true
        run: rclone copy --fast-list --transfers=128 --retries=10 cache:kiwibrowser-next-builds-${{ matrix.platform }}/ $HOME/kiwibrowser-next-builds-${{ matrix.platform }}

      - name: Transferring build to the standard Kiwi Browser run ID
        continue-on-error: true
        run: rclone copy --fast-list --transfers=128 --retries=10 cache:kiwibrowser-next-builds-${{ matrix.platform }}/ cache:kiwibrowser-builds/${{ github.run_id }}/${{ matrix.platform }}

      - name: Listing files
        continue-on-error: true
        run: |
          echo $HOME
          ls -la $HOME/kiwibrowser-next-builds-${{ matrix.platform }}

      - name: Uploading APK
        continue-on-error: true
        uses: actions/upload-artifact@v1
        with:
          name: apk-${{ matrix.platform }}
          path: /home/runner/kiwibrowser-next-builds-${{ matrix.platform }}/

  sign_and_upload:
    runs-on: ubuntu-latest
    needs: build

    steps:
      - name: Installing rclone
        continue-on-error: true
        run: curl https://rclone.org/install.sh | sudo bash
    
      - name: Creating rclone config
        continue-on-error: true
        run: |
          mkdir -p $HOME/.config/rclone/
          echo '[cache]' > $HOME/.config/rclone/rclone.conf
          echo 'type = sftp' >> $HOME/.config/rclone/rclone.conf
          echo 'host = ${{ secrets.STORAGE_HOST }}' >> $HOME/.config/rclone/rclone.conf
          echo 'user = storage' >> $HOME/.config/rclone/rclone.conf
          echo 'key_pem = ${{ secrets.STORAGE_KEY }}' >> $HOME/.config/rclone/rclone.conf

      - name: Creating release
        continue-on-error: true
        id: create_release
        uses: actions/create-release@v1.1.4
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        with:
          owner: "kiwibrowser"
          repo: "src.next"
          tag_name: ${{ github.run_id }}
          release_name: Generation ${{ github.run_id }}
          draft: false
          prerelease: true
          body: |
            This version will replace your currently installed Kiwi Browser (com.kiwibrowser.browser).
            If you have important data, make sure to backup them or save them before upgrading to this version.

            This release was automatically generated from GitHub ${{ github.ref }} in run ID ${{ github.run_id }}.
            
            Summary:
              - To install / update Kiwi Browser, use "Kiwi-${{ github.run_id }}-arm64-github.apk".
              If it doesn't work, try again using "Kiwi-${{ github.run_id }}-arm64-playstore.apk" (if it exists).

            Detailed information about the different files:
              - ".map" files are files that developers can use to investigate crashes (ProGuard mapping files), these files are not needed to run the browser and are for developers only.
              - ".apk" files are packages that you have to install to use Kiwi Browser.

            The filenames are in the form "Kiwi-[BUILD_VERSION]-[ARCHITECTURE]-[SIGNATURE_TYPE].apk"

            Build version:
              - Everytime a change is introduced in Kiwi Browser, a new build version is generated.

            Architecture:
              - "-arm64" is compatible with modern devices and offers the best performance.
              - "-arm" is compatible with almost all devices and uses less memory.
              - "-x86" and "-x64" builds are compatible with emulators and Intel compatible tablets.
                
            Signature type:
              - On Android, applications have to be signed by a developer before they can be installed.

            Kiwi has two types of builds:

            Signed by the developer:
              - "-github.apk" are builds signed using the official developer key.
            A signed build is a build that comes straight from the GitHub official repository and is always the most updated.

            Play Certified by Google:
              - Once in a while, we send a "-github.apk" build to be reviewed and signed by Google.
            Google reviews the application, checks that the application is not malicious, adds the "Google Play Certified" badge, signs the file and this becomes "-playstore.apk".
            
            We then distribute "-playstore.apk" on Google Play, XDA-Developers, Samsung and other app stores.
            
            This process takes some time and is partially manual so not all GitHub builds have a "-playstore.apk".
            
            On Android, you can install an update to an application only if it was signed by the same developer as the version that you currently have installed:
              - You can install a "-github.apk" build on top of a "-github.apk" build, and a "-playstore.apk" build on top of a "-playstore.apk" build.
              - You cannot install a "-playstore.apk" build on top of a "-github.apk" build.
                
            Essentially, if you downloaded Kiwi from an app store, you need to use the "-playstore.apk" files or uninstall the version of Kiwi you have and start using the "-github.apk" version.

      - name: Downloading artifact (arm)
        continue-on-error: true
        uses: actions/download-artifact@v1
        with:
          name: apk-arm

      - name: Downloading artifact (arm64)
        continue-on-error: true
        uses: actions/download-artifact@v1
        with:
          name: apk-arm64

      - name: Downloading artifact (x86)
        continue-on-error: true
        uses: actions/download-artifact@v1
        with:
          name: apk-x86

      - name: Downloading artifact (x64)
        continue-on-error: true
        uses: actions/download-artifact@v1
        with:
          name: apk-x64

      - name: Signing and uploading release to GitHub and send to the Play Store
        continue-on-error: true
        if: ${{ github.repository_owner == 'kiwibrowser' && contains(github.event.inputs.prepareRelease, 'yes') }}
        run: |
          curl 'https://${{ secrets.RELEASE_HOST }}/?run_id=${{ github.run_id }}&dk=${{ secrets.DEPLOY_KEY }}&publish=1&target=aab'

      - name: Downloading artifacts from storage
        continue-on-error: true
        if: ${{ github.repository_owner == 'kiwibrowser' }}
        run: |
          rclone copy --fast-list --transfers=128 --retries=100 cache:kiwibrowser-builds/${{ github.run_id }}/arm/ ./apk-arm 
          rclone copy --fast-list --transfers=128 --retries=100 cache:kiwibrowser-builds/${{ github.run_id }}/arm64/ ./apk-arm64
          rclone copy --fast-list --transfers=128 --retries=100 cache:kiwibrowser-builds/${{ github.run_id }}/x86/ ./apk-x86
          rclone copy --fast-list --transfers=128 --retries=100 cache:kiwibrowser-builds/${{ github.run_id }}/x64/ ./apk-x64

      - name: Uploading release asset (arm-signed)
        continue-on-error: true
        if: ${{ github.repository_owner == 'kiwibrowser' }}
        uses: actions/upload-release-asset@v1
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        with:
          upload_url: ${{ steps.create_release.outputs.upload_url }}
          asset_path: ./apk-arm/ChromePublic-DevSigned.apk
          asset_name: com.kiwibrowser.browser-${{ github.run_id }}-arm-github.apk
          asset_content_type: application/vnd.android.package-archive

      - name: Uploading release asset (arm64-signed)
        continue-on-error: true
        if: ${{ github.repository_owner == 'kiwibrowser' }}
        uses: actions/upload-release-asset@v1
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        with:
          upload_url: ${{ steps.create_release.outputs.upload_url }}
          asset_path: ./apk-arm64/ChromePublic-DevSigned.apk
          asset_name: com.kiwibrowser.browser-${{ github.run_id }}-arm64-github.apk
          asset_content_type: application/vnd.android.package-archive

      - name: Uploading release asset (x86-signed)
        continue-on-error: true
        if: ${{ github.repository_owner == 'kiwibrowser' }}
        uses: actions/upload-release-asset@v1
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        with:
          upload_url: ${{ steps.create_release.outputs.upload_url }}
          asset_path: ./apk-x86/ChromePublic-DevSigned.apk
          asset_name: com.kiwibrowser.browser-${{ github.run_id }}-x86-github.apk
          asset_content_type: application/vnd.android.package-archive

      - name: Uploading release asset (x64-signed)
        continue-on-error: true
        if: ${{ github.repository_owner == 'kiwibrowser' }}
        uses: actions/upload-release-asset@v1
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        with:
          upload_url: ${{ steps.create_release.outputs.upload_url }}
          asset_path: ./apk-x64/ChromePublic-DevSigned.apk
          asset_name: com.kiwibrowser.browser-${{ github.run_id }}-x64-github.apk
          asset_content_type: application/vnd.android.package-archive

      - name: Uploading dev asset (arm-signed)
        continue-on-error: true
        if: ${{ github.repository_owner == 'kiwibrowser' }}
        uses: actions/upload-release-asset@v1
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        with:
          upload_url: ${{ steps.create_release.outputs.upload_url }}
          asset_path: ./apk-arm/ChromePublic-Next-DevSigned.apk
          asset_name: com.kiwibrowser.browser.dev-${{ github.run_id }}-arm-github.apk
          asset_content_type: application/vnd.android.package-archive

      - name: Uploading dev asset (arm64-signed)
        continue-on-error: true
        if: ${{ github.repository_owner == 'kiwibrowser' }}
        uses: actions/upload-release-asset@v1
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        with:
          upload_url: ${{ steps.create_release.outputs.upload_url }}
          asset_path: ./apk-arm64/ChromePublic-Next-DevSigned.apk
          asset_name: com.kiwibrowser.browser.dev-${{ github.run_id }}-arm64-github.apk
          asset_content_type: application/vnd.android.package-archive

      - name: Uploading dev asset (x86-signed)
        continue-on-error: true
        if: ${{ github.repository_owner == 'kiwibrowser' }}
        uses: actions/upload-release-asset@v1
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        with:
          upload_url: ${{ steps.create_release.outputs.upload_url }}
          asset_path: ./apk-x86/ChromePublic-Next-DevSigned.apk
          asset_name: com.kiwibrowser.browser.dev-${{ github.run_id }}-x86-github.apk
          asset_content_type: application/vnd.android.package-archive

      - name: Uploading dev asset (x64-signed)
        continue-on-error: true
        if: ${{ github.repository_owner == 'kiwibrowser' }}
        uses: actions/upload-release-asset@v1
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        with:
          upload_url: ${{ steps.create_release.outputs.upload_url }}
          asset_path: ./apk-x64/ChromePublic-Next-DevSigned.apk
          asset_name: com.kiwibrowser.browser.dev-${{ github.run_id }}-x64-github.apk
          asset_content_type: application/vnd.android.package-archive

      - name: Send announcement on Discord
        continue-on-error: true
        if: contains(github.event.inputs.announceOnDiscord, 'yes')
        run: |
          curl -H 'Content-Type: application/json' -X POST -d '{"username": "Kiwi Builder (Next)", "content": "A new build of Kiwi Browser Next (preview version) is available. This version will replace your currently installed Kiwi Browser (com.kiwibrowser.browser) {Build Hunter} <@&914702266630561852> - https://github.com/kiwibrowser/src.next/releases/tag/${{ github.run_id }}"}' ${{ secrets.DISCORD_WEBHOOK }}
      
      - name: Send announcement on Telegram
        continue-on-error: true
        run: |
          curl -H "Content-Type: application/json" -X POST -d '{"text":"A new build of Kiwi Browser Next (preview version) is available. \n Version :[${{ github.run_id }}](https://github.com/kiwibrowser/src.next/releases/tag/${{ github.run_id }})", "chat_id":"@kiwibrowserbuilds","parse_mode" : "markdown","reply_markup" : {"inline_keyboard": [[{"text": "x86", "url": "https://github.com/kiwibrowser/src.next/releases/download/${{ github.run_id }}/com.kiwibrowser.browser-${{ github.run_id }}-x86-github.apk"},{"text": "x64", "url": "https://github.com/kiwibrowser/src.next/releases/download/${{ github.run_id }}/com.kiwibrowser.browser-${{ github.run_id }}-x64-github.apk"}],[{"text": "arm", "url": "https://github.com/kiwibrowser/src.next/releases/download/${{ github.run_id }}/com.kiwibrowser.browser-${{ github.run_id }}-arm-github.apk"},{"text": "arm64", "url": "https://github.com/kiwibrowser/src.next/releases/download/${{ github.run_id }}/com.kiwibrowser.browser-${{ github.run_id }}-arm64-github.apk"}],[{"text": ".DEV x86", "url": "https://github.com/kiwibrowser/src.next/releases/download/${{ github.run_id }}/com.kiwibrowser.browser.dev-${{ github.run_id }}-x86-github.apk"},{"text": ".DEV x64", "url": "https://github.com/kiwibrowser/src.next/releases/download/${{ github.run_id }}/com.kiwibrowser.browser.dev-${{ github.run_id }}-x64-github.apk"}],[{"text": ".DEV arm", "url": "https://github.com/kiwibrowser/src.next/releases/download/${{ github.run_id }}/com.kiwibrowser.browser.dev-${{ github.run_id }}-arm-github.apk"},{"text": ".DEV arm64", "url": "https://github.com/kiwibrowser/src.next/releases/download/${{ github.run_id }}/com.kiwibrowser.browser.dev-${{ github.run_id }}-arm64-github.apk"}]]}}' https://api.telegram.org/bot${{ secrets.TELEGRAM_TOKEN }}/sendMessage

