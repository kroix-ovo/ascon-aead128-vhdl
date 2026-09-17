FROM ghdl/ghdl:6.0.0-mcode-ubuntu-24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends make python3 python3-pip iverilog verilator \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
COPY verification/requirements.txt /tmp/ascon-requirements.txt
RUN python3 -m pip install --break-system-packages -r /tmp/ascon-requirements.txt

COPY . /work

CMD ["bash", "-lc", "KAT_LIMIT=8 make model-test permutation-test ghdl-test vhdl-textio-test iverilog-test verilator-test"]
