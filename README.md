# ReSurf (Swift)

ReSurf rewritten as a native Mac app on the Mac's own WebKit. The tabs (favourites on the left, the others on
the right), the page in a card, Search in the middle, Google's results in the ReSurf look. A tab is made when it
is looked at and sleeps after half an hour alone (unless it plays sound or uses the camera or microphone), coming
back where it was; ads and trackers are stopped inside WebKit (a content rule list). Ideas taken from Search
(github.com/driceroland/Search, MIT).

    ./build.sh            # build/ReSurf.app
    ./build.sh --install  # into /Applications/ReSpace
    build/ReSurf.app/Contents/MacOS/ReSurf --render <dir>   # its views as pictures, with made-up pages
