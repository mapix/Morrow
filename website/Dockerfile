FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY deploy/nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html styles.css tokens.css base.css app.js /usr/share/nginx/html/
COPY assets/ /usr/share/nginx/html/assets/
COPY downloads/ /usr/share/nginx/html/downloads/
EXPOSE 8080
