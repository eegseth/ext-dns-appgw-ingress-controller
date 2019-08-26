FROM mcr.microsoft.com/powershell:7.0.0-preview.3-alpine-3.10
RUN mkdir /etc/appgw-external-dns
COPY update-dns.ps1 /etc/appgw-external-dns/update-dns.ps1
CMD ["pwsh", "-f", "/etc/appgw-external-dns/update-dns.ps1"]