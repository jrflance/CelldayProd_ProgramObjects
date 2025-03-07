--liquibase formatted sql

--changeset MHoward:0D5552 stripComments:false runOnChange:true endDelimiter:/
-- noqa: disable=all
/***************************************************************************

	  Author : Brandon Stahl

Date Created : 2017-04-01 

 Description : This Sproc inserts pins reported by TracFone into a table and 
				stores the relevant invoice data. A results file is then 
				produced and marked with the status, so that accounting can 
				resolve any issues with the billing.

 BS20170526 : Updated the report to return pins that are not found on the 
			  product serial number table on the results file. Added a new
			  process to accommodate for pins added to the redemption log
			  with the consignment upload job.

 BS20170619 : Updated report to only adding data regarding the redemptions
              to the redemption log.

 BS20170622 : Added logic to mark RTRs.

 BS20170627 : Added additional statuses, and changed logic to allow pins 
			  redeemed to be inserted into redemption log. 

MB20180315	: Added "OR cvm.service_Tag = tp.Item" to every time the
			  CarrierSetup.tblCommonVendorProductMapping was used.

MR20200317  : Added vendor discrepancy insert logic.

MR20200324  : limited the discrepancies to upload into table only if it is not RTR as well as Sucess
			: Also changed the invoice date to be the Toss_Redemption_Date

MH20210913  : added check for RTR products that are not mapped to CarrierSetup.tblCommonVendorProductMapping
			  
MH20211006  : Changed Cellday_Accounting.acct.VendorInvoice JOIN to Toss_Redemption_Date instead of Invoice_Date

MH20211018  : Added WHERE statement to Vendor Invoice Insert to avoid duplicate Invoices on Cellday_Accounting.Acct.VendorInvoice

MH20240215	: Removed ParentItemID to accomidate activation fee
*****************************************************************************/
-- noqa: enable=all
CREATE OR ALTER PROC [Recon].[P_Upload_Tracfone_Redemption]
AS
BEGIN
    BEGIN TRY
        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

        --1. insert txn
        DECLARE @Delimiter VARCHAR(16);

        SELECT
            @Delimiter = Delimiter
        FROM
            Recon.tblVendorSetup
        WHERE
            Id = 24;

        SET @Delimiter = ISNULL(@Delimiter, ',');

        TRUNCATE TABLE CellDayTemp.Tracfone.tblTransRedemptionRecon;

        INSERT INTO CellDayTemp.Tracfone.tblTransRedemptionRecon
        (
            TF_SERIAL_NUM,
            Item,
            Description,
            Product_Code,
            PO_No,
            Unit_Selling_Price,
            Shipped_Date,
            Customer_Name,
            Customer_Number,
            Invoice_No,
            Invoice_Date,
            Toss_Redemption_Date,
            UserName
        )
        SELECT
            B.Chr1,
            B.Chr2,
            B.Chr3,
            B.Chr4,
            CASE
                WHEN LEN(B.Chr5) = 0
                    THEN '0'
                ELSE CAST(B.Chr5 AS VARCHAR(20))
            END AS [PO_No],
            CASE
                WHEN LEN(B.Chr6) = 0
                    THEN 0.00
                ELSE CAST(REPLACE(B.Chr6, '$', '') AS DECIMAL(9, 2))
            END AS [Unit_Selling_Price],
            CASE
                WHEN LEN(B.Chr7) = 0
                    THEN NULL
                ELSE CAST(B.Chr7 AS DATE)
            END AS [Shipped_Date],
            B.Chr8 AS Customer_name,
            B.Chr9 AS Customer_Number,
            CASE
                WHEN LEN(B.Chr10) = 0
                    THEN NULL
                ELSE CAST(B.Chr10 AS INT)
            END AS [Invoice_No],
            CAST(B.Chr11 AS DATE) AS Invoice_Date,
            CAST(REPLACE(REPLACE(B.Chr12, CHAR(10), ''), CHAR(13), '') AS DATE) AS Toss_Redemption_Date,
            B.Chr13 AS UserName
        FROM
            Recon.tblPlainText AS A --CROSS APPLY Recon.fnEDITextParseByPass(@Delimiter,
        --                                  '"', DEFAULT,
        --                                  LTRIM(RTRIM(A.PlainText)),
        --                                  0) B
        CROSS APPLY dbo.SplitText(LTRIM(RTRIM(A.PlainText)), @Delimiter, '"') AS B
        WHERE
            ISDATE(B.Chr11) = 1;

        /************************************REPORT STARTS HERE**********************************/
        IF OBJECT_ID('tempdb..#tempProcess') IS NOT NULL
            BEGIN
                DROP TABLE #tempProcess;
            END;

        --Inserts all the records from the upload file, orders the serial numbers and adds a status column.
        SELECT
            ROW_NUMBER() OVER (PARTITION BY tu.TF_SERIAL_NUM ORDER BY tu.RowNum DESC) AS rnum,
            tu.RowNum,
            tu.TF_SERIAL_NUM,
            tu.Item,
            tu.Description,
            tu.Product_Code,
            tu.PO_No,
            tu.Unit_Selling_Price,
            tu.Shipped_Date,
            tu.Customer_Name,
            tu.Customer_Number,
            tu.Invoice_No,
            tu.Invoice_Date,
            tu.Toss_Redemption_Date,
            CAST(NULL AS INT) AS [Order_Id],
            CAST(NULL AS INT) AS [ProductSerialNum_ID],
            CAST(NULL AS VARCHAR(100)) AS [Status],
            tu.UserName
        INTO #tempProcess
        FROM CellDayTemp.Tracfone.tblTransRedemptionRecon AS tu;

        --Marks any Vendor product codes that are not mapped in system.
        UPDATE #tempProcess
        SET
            [Status] = 'Product Needs Mapped'
        FROM
            #tempProcess AS tp
        WHERE
            NOT EXISTS
            (
                SELECT
                    1
                FROM
                    CarrierSetup.tblCommonVendorProductMapping AS cvm
                WHERE
                    cvm.Vendor_Product_ID = tp.Item
                    OR cvm.Service_Tag = tp.Item
            );

        --MB20180315 
        --BS20170622			
        --Marks RTRs
        UPDATE #tempProcess
        SET
            [Status] = 'RTR'
        FROM
            #tempProcess AS tp
        JOIN CarrierSetup.tblCommonVendorProductMapping AS cpm
            ON (cpm.Vendor_Product_ID = tp.Item) OR (cpm.Service_Tag = tp.Item) --MB20180315 
        JOIN Products.tblProductCarrierMapping AS pcm
            ON pcm.ProductId = cpm.Product_ID
        JOIN dbo.Products AS p
            ON pcm.ProductId = p.Product_ID AND p.Product_Type = 1;

        --Marks additional RTRs
        UPDATE #tempProcess --MH20210913
        SET
            [Status] = 'RTR'
        FROM
            #tempProcess AS tp
        WHERE
            tp.customer_number = 'RTRTCR'
            AND tp.[Status] = 'Product Needs Mapped';

        IF OBJECT_ID('tempdb..#Product_SerialNum_Preprocessed') IS NOT NULL
            BEGIN
                DROP TABLE #Product_SerialNum_Preprocessed;
            END;

        --Finds the first decommissioned and non-decommissioned record
        SELECT
            ROW_NUMBER() OVER (PARTITION BY psn1.Batch_txt ORDER BY psn1.Create_Dtm ASC) AS Rnum1,
            psn1.ProductSerialNum_ID AS Stat1SerialNum_ID,
            ROW_NUMBER() OVER (PARTITION BY psn0.Batch_txt ORDER BY psn0.Create_Dtm ASC) AS Rnum0,
            psn0.ProductSerialNum_ID AS Stat0SerialNum_ID,
            tp.Item,
            tp.TF_SERIAL_NUM AS Batch_txt
        INTO #Product_SerialNum_Preprocessed
        FROM
            #tempProcess AS tp
        JOIN CarrierSetup.tblCommonVendorProductMapping AS cpm
            ON (cpm.Vendor_Product_ID = tp.Item) OR (cpm.Service_Tag = tp.Item) --MB20180315 
        JOIN Products.tblProductCarrierMapping AS pcm
            ON pcm.ProductId = cpm.Product_ID
        LEFT JOIN dbo.Product_SerialNum AS psn1 WITH (INDEX (index_Product_SerialNum_nonclustered))
            ON
                psn1.Batch_txt = tp.TF_SERIAL_NUM
                AND psn1.Status_ID = 1
                AND cpm.Product_ID = psn1.Product_ID
        LEFT JOIN dbo.Product_SerialNum AS psn0 WITH (INDEX (index_Product_SerialNum_nonclustered))
            ON
                psn0.Batch_txt = tp.TF_SERIAL_NUM
                AND psn0.Status_ID = 0
                AND cpm.Product_ID = psn0.Product_ID
        WHERE
            ISNULL(tp.Status, '') <> 'Product Needs Mapped';

        --Adds the correct Product_SerialNum_ID to the pin reported as redeemed.
        UPDATE #tempProcess ---Product ID
        SET
            [ProductSerialNum_ID] = ISNULL(psnp1.Stat1SerialNum_ID, psnp0.Stat1SerialNum_ID)
        FROM
            #tempProcess AS tp
        LEFT JOIN #Product_SerialNum_Preprocessed AS psnp1
            ON
                psnp1.Batch_txt = tp.TF_SERIAL_NUM
                AND tp.Item = psnp1.Item
                AND tp.rnum = 1
                AND psnp1.Stat1SerialNum_ID IS NOT NULL
        LEFT JOIN #Product_SerialNum_Preprocessed AS psnp0
            ON
                psnp0.Batch_txt = tp.TF_SERIAL_NUM
                AND tp.Item = psnp0.Item
                AND tp.rnum = 1
                AND psnp0.Stat1SerialNum_ID IS NULL;

        --Grabs all the orders where the pins were redeemed.
        UPDATE tp
        SET
            tp.Order_Id = IIF(n.Void = 1 AND n.OrderTotal < 0, ISNULL(so.ID, o.ID), o.ID)
        FROM
            #tempProcess AS tp
        JOIN dbo.Product_SerialNum AS psn
            ON psn.ProductSerialNum_ID = tp.ProductSerialNum_ID
        JOIN dbo.Orders AS o
            ON o.Order_No = psn.Order_No AND o.SKU = psn.SerialNumber_txt
        --AND o.ParentItemID = 0			--MH20240215 (removed)
        JOIN dbo.Products AS p --MH20240215
            ON o.Product_ID = p.Product_ID AND ISNULL(p.Product_Type, 0) IN (0, 1, 3)
        JOIN dbo.Order_No AS n
            ON n.Order_No = o.Order_No
        LEFT JOIN dbo.Order_No AS s
            ON s.AuthNumber = CAST(n.Order_No AS VARCHAR(11))
        LEFT JOIN dbo.Orders AS so
            ON so.Order_No = s.Order_No;

        IF OBJECT_ID('tempdb..#tempTracFoneRedemtionLog') IS NOT NULL
            BEGIN
                DROP TABLE #tempTracFoneRedemtionLog;
            END;

        --Preps Data to be inserted/ updated in the redemption log.
        SELECT
            tp.Order_Id,
            n.DateFilled,
            (o.Price - o.DiscAmount - SUM(ISNULL(oc.Commission_Amt, 0))) AS [OrderAmount],
            tp.ProductSerialNum_ID
        INTO #tempTracFoneRedemtionLog
        FROM
            #tempProcess AS tp
        LEFT JOIN dbo.Orders AS o
            ON o.ID = tp.Order_Id
        LEFT JOIN dbo.Order_No AS n
            ON n.Order_No = o.Order_No
        LEFT JOIN dbo.Order_Commission AS oc
            ON oc.Orders_ID = o.ID
        WHERE
            ISNULL(tp.Status, '') = ''
        GROUP BY
            tp.Order_Id,
            n.DateFilled,
            o.Price,
            o.DiscAmount,
            tp.ProductSerialNum_ID;

        --Inserts records into redemption log.
        INSERT INTO CellDay_history.Tracfone.tblTracTransRedemptionHistory
        (
            ProductSerialNum_ID,
            Order_ID,
            CollectionAmount,
            RedemptionDate,
            ExposureDATE
        )
        SELECT
            tp.ProductSerialNum_ID,
            ttrl.Order_Id,
            ISNULL(ttrl.OrderAmount, 0) AS [OrderAmount],
            tp.Toss_Redemption_Date,
            ttrl.DateFilled
        --BS20170627
        FROM
            #tempProcess AS tp
        LEFT JOIN #tempTracFoneRedemtionLog AS ttrl
            ON ttrl.ProductSerialNum_ID = tp.ProductSerialNum_ID
        WHERE
            ISNULL(tp.[Status], '') = ''
            AND tp.ProductSerialNum_ID IS NOT NULL
            AND tp.rnum = 1
            AND NOT EXISTS
            (
                SELECT
                    1
                FROM
                    CellDay_history.Tracfone.tblTracTransRedemptionHistory AS ttrh
                WHERE
                    ttrh.ProductSerialNum_ID = tp.ProductSerialNum_ID
            );

        --Updates preexisting records with redemption data.
        UPDATE CellDay_history.Tracfone.tblTracTransRedemptionHistory
        SET
            Order_ID = ttrl.Order_Id,
            CollectionAmount = ttrl.OrderAmount,
            RedemptionDate = tp.Toss_Redemption_Date,
            ExposureDATE = ttrl.DateFilled
        FROM
            #tempProcess AS tp
        JOIN #tempTracFoneRedemtionLog AS ttrl
            ON ttrl.ProductSerialNum_ID = tp.ProductSerialNum_ID
        JOIN CellDay_history.Tracfone.tblTracTransRedemptionHistory AS ttrh
            ON ttrh.ProductSerialNum_ID = tp.ProductSerialNum_ID
        WHERE
            tp.rnum = 1;

        IF OBJECT_ID('tempdb..#Results') IS NOT NULL
            BEGIN
                DROP TABLE #Results;
            END;

        SELECT
            ISNULL(psn.ProductSerialNum_ID, -1) AS ProductSerialNum_ID,
            ISNULL(psn.Status_ID, 0) AS Status_ID,
            ISNULL(psn.SerialNumAvailable_Flg, 'N') AS SerialNumAvailable_Flg,
            tp.Item,
            tp.[Description],
            tp.Product_Code,
            tp.PO_No,
            ISNULL(ttfr.Order_Id, -1) AS [OrderID],
            ttfr.DateFilled,
            tp.Unit_Selling_Price,
            ISNULL(ttfr.OrderAmount, 0) AS [TCetraAmount],
            tp.TF_SERIAL_NUM,
            tp.Shipped_Date,
            tp.Toss_Redemption_Date,
            --BS20170627
            (ISNULL(ttfr.OrderAmount, 0) - tp.Unit_Selling_Price) AS [AmountDiff],
            DATEDIFF(DAY, ISNULL(ttfr.DateFilled, '1800-01-01'), ISNULL(tp.Toss_Redemption_Date, '1800-01-01')) AS [DateDiff],
            CASE
                WHEN tp.Status IS NULL
                    THEN
                        CASE
                            WHEN tp.ProductSerialNum_ID IS NULL
                                THEN 'Missing'
                            --BS20170627									
                            WHEN
                                psn.Status_ID = 1
                                AND psn.SerialNumAvailable_Flg = 'Y'
                                THEN 'Redeemed and Not Sold'
                            WHEN
                                psn.Status_ID = 1
                                AND DATEDIFF(DAY, ISNULL(ttfr.DateFilled, '1800-01-01'), ISNULL(tp.Toss_Redemption_Date, '1800-01-01')) < 0
                                THEN 'Uncaught Redeemption Before Sell Date'
                            WHEN
                                psn.Status_ID = 0
                                AND DATEDIFF(DAY, ISNULL(ttfr.DateFilled, '1800-01-01'), ISNULL(tp.Toss_Redemption_Date, '1800-01-01')) < 0
                                THEN 'Caught Redeemption Before Sell Date'
                            ELSE 'Success'
                        END
                ELSE tp.[Status]
            END AS [Status],
            tp.Invoice_Date,
            tp.UserName
        INTO #Results
        FROM
            #tempProcess AS tp
        LEFT JOIN dbo.Product_SerialNum AS psn WITH (INDEX (index_Product_SerialNum_nonclustered))
            ON psn.Batch_txt = tp.TF_SERIAL_NUM
        LEFT JOIN #tempTracFoneRedemtionLog AS ttfr
            ON ttfr.ProductSerialNum_ID = psn.ProductSerialNum_ID;

        TRUNCATE TABLE CellDayTemp.Tracfone.tblTransRedemptionReconResult;

        INSERT INTO CellDayTemp.Tracfone.tblTransRedemptionReconResult
        (
            ProductSerialNum_ID,
            Status_ID,
            SerialNumAvailable_Flg,
            Item,
            [Description],
            Product_Code,
            PO_No,
            OrderID,
            DateFilled,
            Unit_Selling_Price,
            TCetraAmount,
            TF_SERIAL_NUM,
            Shipped_Date,
            Toss_Redemption_Date,
            AmountDiff,
            [DateDiff],
            [Status]
        )
        SELECT
            ProductSerialNum_ID,
            Status_ID,
            SerialNumAvailable_Flg,
            Item,
            [Description],
            Product_Code,
            PO_No,
            OrderID,
            DateFilled,
            Unit_Selling_Price,
            TCetraAmount,
            TF_SERIAL_NUM,
            Shipped_Date,
            Toss_Redemption_Date,
            AmountDiff,
            [DateDiff],
            [Status]
        FROM
            #Results;

        INSERT INTO Cellday_Accounting.acct.VendorInvoice --MR20190711
        (
            InvoiceNo,
            InvoiceDate,
            Process_Id
        )
        SELECT DISTINCT
            CONCAT(YEAR(r.Toss_Redemption_Date), MONTH(r.Toss_Redemption_Date), DAY(r.Toss_Redemption_Date), 'TFredemption') AS InvoiceNo,
            r.Toss_Redemption_Date AS InvoiceDate,
            10 AS Process_ID -- TracfoneRedemption
        FROM
            #Results AS r
        WHERE
            r.Toss_Redemption_Date NOT IN
            ( --MH20211018
                SELECT
                    vi.InvoiceDate
                FROM
                    Cellday_Accounting.acct.VendorInvoice AS vi
                WHERE
                    vi.InvoiceDate = r.Toss_Redemption_Date
                    AND vi.Process_Id = 10
            );

        INSERT INTO Cellday_Accounting.acct.VendorDiscrepancies --MR20190711
        (
            Process_Id,
            DateCreated,
            UserCreated,
            Discrepancy_ID,
            DiscrepancyAmt,
            TransactionID,
            Order_No,
            VendorInvoice_ID
        )
        SELECT
            10 AS process_ID, --TracfoneRedemption
            GETDATE() AS DateCreated,
            r.UserName AS UserCreated,
            CASE
                WHEN r.Status = 'Missing'
                    THEN 14
                WHEN r.Status = 'Redeemed and Not Sold'
                    THEN 20
                WHEN r.Status = 'Uncaught Redeemption Before Sell Date'
                    THEN 21
                WHEN r.Status = 'Caught Redeemption Before Sell Date'
                    THEN 22
                WHEN r.Status = 'Product Needs Mapped'
                    THEN 23
                --WHEN r.status = 'RTR' THEN 24
                ELSE 11
            END AS Discrepancy_ID,
            (r.AmountDiff) AS DiscrepancyAmt,
            r.TF_SERIAL_NUM AS TransactionID,
            r.OrderID AS Order_NO,
            vi.ID AS VendorInvoice_ID
        FROM
            #Results AS r
        JOIN Cellday_Accounting.acct.VendorInvoice AS vi
            --ON vi.InvoiceDate = r.Invoice_Date					--MH20211006
            ON
                vi.InvoiceDate = r.Toss_Redemption_Date --MH20211006
                AND vi.Process_Id = 10 --TracfoneRedemption
        WHERE
            r.Status NOT IN (
                'Success', 'RTR'
            );
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH;
END
-- noqa: disable=all
/
