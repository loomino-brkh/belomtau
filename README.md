# belomtau

# Jumat, 24 Mei 2024

Start zero.

# Sabtu, 25 Mei 2024

OK, the plan is to write the web app that is reliable, portable, secure and not dependant to the hardware of the server.

So, the server must be an appliance of virtual environment. And use docker built on top of it to deploy the code.

# Sabtu, 01 Juni 2024

Baiklah, semakin jelas ini. Jadi, rencananya, kita akan develop django web app dengan docker compose yang di dalamnya mengandung bawang, eh bukan bawang, tapi mengandung redis cache, celery dan postgresql. Serta menggunakan nginx sebagai load balancer nya / reverse proxy. Nanti juga ditambahkan dengan cloudflare tunnel, biar makin ok develop-nya.

Key point:<br />
    - create docker compose and its support directory<br />
    - it contain python, django, redis, celery, postresql, and cloudflare tunnel

# Senin, 10 Juni 2024

Perubahan ide lagi. Jadi, sekarang, idenya adalah menggunakan freebsd sebagai host. Di dalamnya akan diinstall postgres, redis, nginx, dan software lain yang diperlukan. Lalu, build django di dalamnya.<br />

- Ide ini muncul setelah melakukan riset untuk docker compose dan kubernetes mengenai automasi yang tersedia. Ternyata semua mengarah (menurut saya) pada keribetan yang berele-tele. Padahal prinsip awal yang saya pegang adalah "do not reinvent the wheel". Jadi buat apa automasi dengan sesuatu yang baru, padahal sudah ada shell script. Yah, ntah lah. Bisa jadi besok-besok berubah lagi. Hahahaha....