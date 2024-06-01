# belomtau

# Jumat, 24 Mei 2024

Start zero.

# Sabtu, 25 Mei 2024

OK, the plan is to write the web app that is reliable, portable, secure and not dependant to the hardware of the server.

So, the server must be an appliance of virtual environment. And use docker built on top of it to deploy the code.

# Sabtu, 01 Juni 2024

Baiklah, semakin jelas ini. Jadi, rencananya, kita akan develop django web app dengan docker compose yang di dalamnya mengandung bawang, eh bukan bawang, tapi mengandung redis cache dan pestgresql. Serta menggunakan nginx sebagai load balancer nya / reverse proxy. Nanti juga ditambahkan dengan cloudflare tunnel, biar makin ok develop-nya.

Key point:\n
    - create docker compose and its support directory\n
    - it contain python, django, redis, postresql, and cloudflare tunnel