// Offline JPEG measurement only. Uses the caller-installed libjpeg API.
// No product dependency, Adobe code, directory discovery, or output replacement.
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <setjmp.h>
#include <string.h>
#include <errno.h>
#include <jpeglib.h>
struct failure {struct jpeg_error_mgr pub; jmp_buf jump;};
static void failed(j_common_ptr p){struct failure *e=(struct failure*)p->err;(*p->err->output_message)(p);longjmp(e->jump,1);}
int main(int argc,char**argv){
 if(argc!=3){fputs("Usage: jpeg-coefficients SOURCE NEW_PREFIX\n",stderr);return 2;}
 struct jpeg_decompress_struct c={0};struct failure e;c.err=jpeg_std_error(&e.pub);e.pub.error_exit=failed;
 if(setjmp(e.jump)){jpeg_destroy_decompress(&c);return 1;}
 jpeg_create_decompress(&c);FILE*source=fopen(argv[1],"rb");if(!source)return 1;jpeg_stdio_src(&c,source);jpeg_read_header(&c,TRUE);
 if(c.data_precision!=8||c.num_components!=3||c.jpeg_color_space!=JCS_YCbCr){fputs("Only 8-bit YCbCr is admitted\n",stderr);return 3;}
 jvirt_barray_ptr *arrays=jpeg_read_coefficients(&c);
 printf("{\"width\":%u,\"height\":%u,\"precision\":%d,\"components\":[",c.image_width,c.image_height,c.data_precision);
 for(int i=0;i<c.num_components;i++){
  jpeg_component_info *p=&c.comp_info[i];JQUANT_TBL*q=c.quant_tbl_ptrs[p->quant_tbl_no];if(!q)return 4;
  char path[4096];if(snprintf(path,sizeof(path),"%s.c%d.i16le",argv[2],i)>=(int)sizeof(path))return 5;
  FILE*out=fopen(path,"wbx");if(!out){perror("Exclusive coefficient output");return 6;}
  for(JDIMENSION y=0;y<p->height_in_blocks;y++){
   JBLOCKARRAY row=(*c.mem->access_virt_barray)((j_common_ptr)&c,arrays[i],y,1,FALSE);
   for(JDIMENSION x=0;x<p->width_in_blocks;x++)for(int k=0;k<64;k++){
    uint16_t value=(uint16_t)row[0][x][k];unsigned char bytes[2]={(unsigned char)(value&255),(unsigned char)(value>>8)};if(fwrite(bytes,1,2,out)!=2)return 7;
   }
  }
  if(fflush(out)||fclose(out))return 8;
  printf("%s{\"id\":%d,\"h_sampling\":%d,\"v_sampling\":%d,\"block_width\":%u,\"block_height\":%u,\"quant\":[",i?",":"",p->component_id,p->h_samp_factor,p->v_samp_factor,p->width_in_blocks,p->height_in_blocks);
  for(int k=0;k<64;k++)printf("%s%u",k?",":"",q->quantval[k]);printf("]}");
 }
 printf("]}\n");jpeg_finish_decompress(&c);
 /* Independently keep the library's float-IDCT YCbCr stage for readback. */
 rewind(source);jpeg_stdio_src(&c,source);jpeg_read_header(&c,TRUE);
 c.out_color_space=JCS_YCbCr;c.dct_method=JDCT_FLOAT;c.do_fancy_upsampling=FALSE;
 jpeg_start_decompress(&c);char path[4096];
 if(snprintf(path,sizeof(path),"%s.libfloat-ycc-u8",argv[2])>=(int)sizeof(path))return 9;
 FILE*out=fopen(path,"wbx");if(!out)return 10;
 size_t stride=(size_t)c.output_width*c.output_components;JSAMPROW line=malloc(stride);if(!line)return 11;
 while(c.output_scanline<c.output_height){
  if(jpeg_read_scanlines(&c,&line,1)!=1||fwrite(line,1,stride,out)!=stride)return 12;
 }
 jpeg_finish_decompress(&c);jpeg_destroy_decompress(&c);free(line);fclose(source);
 return fclose(out)?13:0;
}
