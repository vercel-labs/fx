FROM python:3.13-slim@sha256:5dde09372dfa8e7762892b2a12619fcf6c23b0b78bce1058a9fa5a3a7a40e68e
ENV TIKTOKEN_CACHE_DIR=/opt/tiktoken-cache PYTHONDONTWRITEBYTECODE=1
RUN python -m pip install --no-cache-dir --only-binary=:all: \
      tiktoken==0.12.0 regex==2026.9.29 requests==2.34.2 \
      certifi==2026.10.23 charset-normalizer==3.5.2 idna==3.20 urllib3==2.8.0 \
    && python -c 'import tiktoken; tiktoken.get_encoding("o200k_base"); tiktoken.get_encoding("cl100k_base")'
USER 65532:65532
ENTRYPOINT ["python"]
