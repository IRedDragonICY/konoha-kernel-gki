load(":image_opts.bzl", "vm_image_opts")
load(":msm_kernel_vm.bzl", "define_msm_vm")
load(":target_variants.bzl", "vm_variants")

target_name = "parrot-tuivm"

def define_parrot_tuivm():
    image_opts = vm_image_opts(
        kernel_offset = 0xE0C00000,
        dtb_offset = 0xE2C00000,
        ramdisk_offset = 0xE2F00000,
        dummy_img_offset = 0xE55F0000,
    )
    for variant in vm_variants:
        define_msm_vm(
            msm_target = target_name,
            variant = variant,
            vm_image_opts = image_opts,
        )
