hugo 
cp -r public/* .
git add .
git commit -m  "new blog $(date "+%Y%m%d-%H%M%S")"
git push origin master