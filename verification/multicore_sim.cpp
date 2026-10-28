// Compiled RTL scoreboard for the full matrix. Input format and metric cycle
// boundaries match tb_multicore.vhd; both compare each beat to the Python oracle.
#include "Vascon_multicore.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <vector>

using Block=std::array<uint32_t,4>;
template<class P> uint64_t bits(const P& p,int start,int n) {
  uint64_t x=0;
  for(int j=0;j<n;++j) {
    if constexpr(std::is_integral_v<P>) x|=uint64_t((p>>(start+j))&1)<<j;
    else x|=uint64_t((p[(start+j)/32]>>((start+j)%32))&1)<<j;
  }
  return x;
}
template<class P> void put(P& p,int start,int n,uint64_t value) {
  for(int j=0;j<n;++j) {
    if constexpr(std::is_integral_v<P>) {
      uint64_t m=uint64_t(1)<<(start+j);
      p=static_cast<P>((uint64_t(p)&~m)|(((value>>j)&1)<<(start+j)));
    } else {
      uint32_t m=uint32_t(1)<<((start+j)%32);
      auto& w=p[(start+j)/32]; w=(w&~m)|(((value>>j)&1)<<((start+j)%32));
    }
  }
}
template<class P> void putblock(P& p,int start,const Block& b) {
  for(int j=0;j<4;++j) put(p,start+j*32,32,b[j]);
}
template<class P> Block getblock(const P& p,int start=0) {
  Block b{};for(int j=0;j<4;++j)b[j]=bits(p,start+j*32,32);return b;
}
Block parseblock(const std::string& s) {
  Block b{}; for(int j=0;j<4;++j)b[j]=std::stoul(s.substr(s.size()-8*(j+1),8),nullptr,16);return b;
}
void check(bool good,const std::string& message) {if(!good)throw std::runtime_error(message);}
std::string hexblock(const Block& b) {
  const char* digits="0123456789abcdef";std::string s;
  for(int j=3;j>=0;--j)for(int k=7;k>=0;--k)s+=digits[(b[j]>>(k*4))&15];return s;
}

int main(int argc,char** argv) {
  try {
    check(argc==7,"usage: SIM DIR CORES BYTES DECRYPT PROFILE FAULT");
    std::string dir=argv[1];const int cores=std::stoi(argv[2]),size=std::stoi(argv[3]);
    const bool dec=std::stoi(argv[4]);const int profile=std::stoi(argv[5]),fault=std::stoi(argv[6]);
    const int blocks=(size+15)/16;
    std::ifstream vectors(dir+"/vectors.txt");check(bool(vectors),"vectors missing");
    Vascon_multicore d; std::string text;
    vectors>>text;putblock(d.key_i,0,parseblock(text));
    vectors>>text;putblock(d.nonce_base_i,0,parseblock(text));
    for(auto* p:{&d.model_id_i,&d.manifest_id_i}) {
      vectors>>text; putblock(*p,0,parseblock(text.substr(32))); putblock(*p,128,parseblock(text.substr(0,32)));
    }
    std::array<Block,12> tags{};
    std::vector<Block> input(12*blocks),expected(12*blocks),quarantine(12*blocks);
    for(int i=0;i<12;++i) {
      vectors>>text;tags[i]=parseblock(text);
      for(int j=0;j<blocks;++j) {
        vectors>>text;input[i*blocks+j]=parseblock(text);
        vectors>>text;expected[i*blocks+j]=parseblock(text);
      }
    }
    check(bool(vectors),"truncated vectors");
    auto edge=[&](){d.clk_i=0;d.eval();d.clk_i=1;d.eval();};
    d.rst_i=1;edge();edge();d.rst_i=0;d.file_valid_i=1;d.decrypt_i=dec;
    d.chunk_bytes_i=size;d.out_ready_i=1;d.bus_in_enable_i=1;edge();d.file_valid_i=0;
    std::ofstream metrics(dir+"/metrics.txt"),output(dir+"/output.txt");
    auto metric=[&](const std::string& name,uint64_t value){metrics<<name<<" "<<value<<"\n";};
    if(fault==12) {
      check(d.done_o&&d.discard_o&&!d.commit_o,"nonce overflow accepted");
      metric("discard_pass",1);return 0;
    }
    std::array<uint64_t,12> sent{},got{},starts{},ends{},busy{},starved{},blocked{},missed{},waits{},lane_beats{},chunk_counts{};
    std::array<uint64_t,12> arb_input{},capacity_input{},setup_input{},bandwidth_input{},arb_output{},external_output{};
    std::array<int,4> fair_input{},fair_output{};
    std::array<bool,12> sent_tag{},got_tag{};
    std::array<bool,4> pending{},tag_offer{};
    std::array<Block,4> offer{};
    std::array<int,4> offer_layer{},offer_offset{},offer_size{},offer_keep{};
    uint64_t first_output=0,last_input=0,last_output=0,bus_input=0,bus_payload=0,bus_output=0,bus_output_payload=0;
    uint32_t rng=0x8135a77d;int credit=0;bool held=false,input_held=false;Block held_data{};
    uint64_t held_meta=0;int held_lane=0;
    for(uint64_t cycle=1;cycle<20000000;++cycle) {
      d.clk_i=0;d.eval();
      rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;
      bool gi=true,go=true,allowed=true;
      if(profile==1)allowed=cycle%8==0;
      if(profile==2)go=cycle%8==0;
      if(profile==3) {
        allowed=cycle%97>20 && (rng&15)!=0;go=cycle%113>31 && ((rng>>4)&15)!=0;
      }
      if(profile==4||profile==5) {
        credit=std::min(credit+(profile==4?10:13),32);int available=credit;
        gi=go=false;
        if(cycle%2==0){if(available>=16){gi=true;available-=16;}if(available>=16)go=true;}
        else {if(available>=16){go=true;available-=16;}if(available>=16)gi=true;}
      }
      d.bus_in_enable_i=gi;d.out_ready_i=go;
      if((fault==8&&cycle==80)||(fault==7&&cycle==1000))d.abort_i=1;
      if(fault==9&&cycle==80)d.rst_i=1;
      if(fault==9&&cycle==81)d.rst_i=0;
      for(int lane=0;lane<cores;++lane) {
        int layer=bits(d.chunk_id_o,lane*4,4),offset=sent[layer];
        if(!pending[lane]&&layer<12) {
          bool payload=offset<size&&allowed&&!(fault==7&&layer==11)&&(profile!=6||lane!=0||cycle%31==0);
          bool tag=offset==size&&dec&&!sent_tag[layer];
          if(payload||tag) {
            pending[lane]=true;tag_offer[lane]=tag;offer_layer[lane]=layer;offer_offset[lane]=offset;
            offer_size[lane]=tag?16:std::min(16,size-offset);
            offer_keep[lane]=(1u<<offer_size[lane])-1;
            offer[lane]=tag?tags[layer]:input[layer*blocks+offset/16];
            if(layer==0&&offset==0) {
              if(fault==3)offer_layer[lane]=1;
              if(fault==4)offer_offset[lane]=16;
              if(fault==5)offer_keep[lane]=0xfffd;
            }
            if(fault==6&&layer==cores&&offset==0)offer_layer[lane]=0;
          }
        }
        put(d.source_valid_i,lane,1,pending[lane]);
        if(pending[lane]) {
          putblock(d.source_data_i,lane*128,offer[lane]);
          put(d.source_keep_i,lane*16,16,offer_keep[lane]);
          put(d.source_tag_i,lane,1,tag_offer[lane]);
          put(d.source_last_i,lane,1,tag_offer[lane]||offer_offset[lane]+offer_size[lane]==size);
          if(fault==16&&offer_layer[lane]==0&&offer_offset[lane]==0)put(d.source_last_i,lane,1,1);
          put(d.source_chunk_i,lane*4,4,offer_layer[lane]);
          put(d.source_offset_i,lane*32,32,offer_offset[lane]);
        }
      }
      d.eval();
      auto data=getblock(d.out_data_o);
      uint64_t meta=uint64_t(d.out_keep_o)|(uint64_t(d.out_last_o)<<16)|(uint64_t(d.out_tag_o)<<17)|
        (uint64_t(d.out_chunk_o)<<18)|(uint64_t(d.out_offset_o)<<22);
      if(held&&!d.rst_i&&!d.abort_i)check(d.out_valid_o&&data==held_data&&meta==held_meta,"stalled output changed");
      held=d.out_valid_o&&!go;held_data=data;held_meta=meta;
      if(input_held&&!d.rst_i&&!d.abort_i)check(d.bus_in_valid_o&&d.bus_in_lane_o==held_lane,"stalled input changed");
      input_held=d.bus_in_valid_o&&!d.bus_in_ready_o;held_lane=d.bus_in_lane_o;
      auto mask=(1u<<cores)-1;
      for(int lane=0;lane<cores;++lane) {
        bool all_input=d.source_valid_i==mask&&d.source_phase_o==mask&&d.source_capacity_o==mask&&gi;
        fair_input[lane]=all_input&&!bits(d.source_ready_o,lane,1)?fair_input[lane]+1:0;
        fair_output[lane]=d.collector_pending_o==mask&&go&&!bits(d.collector_ready_o,lane,1)?fair_output[lane]+1:0;
        check(fair_input[lane]<cores&&fair_output[lane]<cores,"round-robin fairness failure");
        busy[lane]+=bits(d.core_busy_o,lane,1);starved[lane]+=bits(d.input_starved_o,lane,1);
        blocked[lane]+=bits(d.output_blocked_o,lane,1);missed[lane]+=bits(d.tail_missed_o,lane,1);
        waits[lane]+=pending[lane]&&!bits(d.source_ready_o,lane,1);
        if(pending[lane]) {
          if(!bits(d.source_phase_o,lane,1))setup_input[lane]++;
          else if(!bits(d.source_capacity_o,lane,1))capacity_input[lane]++;
          else if(!gi)bandwidth_input[lane]++;
          else if(!bits(d.source_ready_o,lane,1))arb_input[lane]++;
        }
        if(bits(d.collector_pending_o,lane,1)) {
          if(!go)external_output[lane]++;
          else if(!bits(d.collector_ready_o,lane,1))arb_output[lane]++;
        }
        if(pending[lane]&&bits(d.source_ready_o,lane,1)) {
          int layer=bits(d.chunk_id_o,lane*4,4);
          if(tag_offer[lane])sent_tag[layer]=true;
          else {sent[layer]+=std::min(16,size-int(sent[layer]));lane_beats[lane]++;last_input=cycle;}
          pending[lane]=false;
        }
      }
      if(d.bus_in_valid_o&&d.bus_in_ready_o) {
        bus_input++;bus_payload+=d.bus_in_payload_o;if(profile==4||profile==5)credit-=16;
      }
      if(d.out_valid_o&&go) {
        bus_output++;last_output=cycle;int layer=d.out_chunk_o,offset=d.out_offset_o;
        check(layer<12,"invalid output layer");
        if(d.out_tag_o) {
          check(!dec&&!got_tag[layer]&&data==tags[layer],"tag mismatch");got_tag[layer]=true;
        } else {
          if(!first_output)first_output=cycle;
          check(offset==int(got[layer])&&offset<size,"output offset/order mismatch");
          int n=std::min(16,size-offset),idx=layer*blocks+offset/16;
          if(fault!=1&&fault!=2&&fault!=10&&fault!=11&&fault!=13&&fault!=14&&fault!=15) {
            for(int b=0;b<n;++b)check(((data[b/4]>>(8*(b%4)))&255)==((expected[idx][b/4]>>(8*(b%4)))&255),"payload mismatch");
          }
          check(d.out_keep_o==((1u<<n)-1)&&bool(d.out_last_o)==(offset+n==size),"output framing mismatch");
          quarantine[idx]=data;got[layer]+=n;bus_output_payload++;
        }
        if(profile==4||profile==5)credit-=16;
      }
      check(credit>=0,"memory service exceeded credit budget");
      d.clk_i=1;d.eval();
      for(int lane=0;lane<cores;++lane) {
        int layer=bits(d.chunk_id_o,lane*4,4);
        if(bits(d.chunk_start_o,lane,1)){check(!starts[layer],"duplicate chunk start");starts[layer]=cycle;}
        if(bits(d.chunk_done_o,lane,1)){ends[layer]=cycle;chunk_counts[lane]++;}
      }
      if(d.commit_o) {
        check(d.done_o&&!d.discard_o&&!fault,"premature/failed file commit");
        for(int layer=0;layer<12;++layer)check(got[layer]==uint64_t(size)&&ends[layer],"commit before all chunks complete");
      }
      if(fault==9&&cycle==85) {
        check(!d.busy_o&&!d.commit_o&&!d.out_valid_o,"reset did not flush");metric("reset_flush_pass",1);return 0;
      }
      if(d.done_o) {
        if(fault){check(d.discard_o&&!d.commit_o,"failed file released");metric("discard_pass",1);return 0;}
        check(d.commit_o&&!d.discard_o,"valid file failed");
        for(int layer=0;layer<12;++layer) {
          check(sent[layer]==uint64_t(size)&&got[layer]==uint64_t(size),"incomplete file");
          check(dec||got_tag[layer],"missing encryption tag");
          check(starts[layer]&&ends[layer]>starts[layer],"chunk timestamps missing");
          for(int j=0;j<blocks;++j)output<<hexblock(quarantine[layer*blocks+j])<<"\n";
          metric("chunk_start_"+std::to_string(layer),starts[layer]);metric("chunk_end_"+std::to_string(layer),ends[layer]);
        }
        metric("cycles",cycle);metric("first_output",first_output);metric("last_input",last_input);metric("last_output",last_output);
        metric("bus_input",bus_input);metric("bus_payload",bus_payload);metric("bus_output",bus_output);metric("bus_output_payload",bus_output_payload);
        for(int lane=0;lane<cores;++lane) {
          auto suffix=std::to_string(lane);
          metric("busy_"+suffix,busy[lane]);metric("starved_"+suffix,starved[lane]);metric("blocked_"+suffix,blocked[lane]);
          metric("missed_tail_"+suffix,missed[lane]);metric("source_wait_"+suffix,waits[lane]);
          metric("input_arbitration_wait_"+suffix,arb_input[lane]);metric("input_capacity_wait_"+suffix,capacity_input[lane]);
          metric("input_setup_wait_"+suffix,setup_input[lane]);metric("input_bandwidth_wait_"+suffix,bandwidth_input[lane]);
          metric("output_arbitration_wait_"+suffix,arb_output[lane]);metric("output_external_wait_"+suffix,external_output[lane]);
          metric("input_beats_"+suffix,lane_beats[lane]);metric("chunks_"+suffix,chunk_counts[lane]);
        }
        std::cout<<"MULTICORE_PASS\n";return 0;
      }
    }
    throw std::runtime_error("multicore timeout");
  }catch(const std::exception& e){std::cerr<<e.what()<<"\n";return 1;}
}
