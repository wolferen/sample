require 'image_processing/mini_magick'

module PdfDocumentInteractors
  class CreateRecords
    include Interactor

    def call
      @picture_ids = []
      ActiveRecord::Base.transaction do
        pdf = MiniMagick::Image.open(context.pdf_document.pdf_file)
        @pdf_pages = pdf.pages
        @product_name = context.pdf_document&.product&.name
        @filename = context.pdf_document.pdf_file.blob.filename.to_s.chomp('.pdf')
        context.pdf_document.update!(status: :processing_pdf)
        process_pages
        context.pdf_document.update!(status: :creating_pictures)
        process_pictures
        context.pdf_document.update!({ status: :finished, picture_ids: @picture_ids })
      end

      Picture.find(@picture_ids).each(&:create_all_variants)
    rescue StandardError => e
      context.fail!(error: e)
    end

    private

    def process_pages
      @pictures = {}
      @pdf_pages.each_with_index do |page, index|
        page_image = Tempfile.new(file_name(index), binmode: true)
        # make it accessible to format
        MiniMagick::Tool::Convert.new do |convert|
          convert.colorspace 'sRGB'
          convert << page.path
          convert << page_image.path
        end
        # format to png
        image = MiniMagick::Image.open(page_image.path)
        image.format 'png'
        @pictures[file_name(index).to_sym] = image
      end
    end

    def process_pictures
      @pictures.each_with_index do |picture, index|
        blob = ActiveStorage::Blob.create_after_upload!(
          io: picture.second.tempfile.open,
          filename: file_name(index),
          content_type: 'image/png'
        )

        picture = Picture.create!({
                                    imageable: context.pdf_document.client,
                                    draft: false,
                                    seo_title: @product_name.presence || file_name(index)
                                  })

        picture.image.attach(blob)
        picture.save!

        @picture_ids << picture.id
      end
    end

    def file_name(index)
      "#{@filename}_page_#{index + 1}"
    end
  end
end
