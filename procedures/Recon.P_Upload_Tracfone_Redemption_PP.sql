--liquibase formatted sql

--changeset MHoward:0D5551 stripComments:false runOnChange:true endDelimiter:/
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

 PS20171107	: Updated the report and added a new process so that it can run the job for Page plus redemption file.	

 MB20180117 : Added the status of 'DOUBLED' for Rnum = 2

 MR20190814 : Removed joining and mapping check using "Item" since PP pins are not mapped
			:	in the CarrierSetup.tblCommonVendorProductMapping.
			: Removed status' of 'Product Needs Mapped!' and "RTR"

 MR20190919	: Removed the hidden characters from the end of the Unit_selling_price column

 MR20200317 : Added logic to insert into VendorDiscrepancy tables. Added UserName.

 MR20200324 : Removed the hidden characters from the end of the UserName column 
			: Limited error codes to not in RTR and Success

 MH20210901 : Excluded 'Duplicate' status for Vendor error reporting because this is not an error that requires action
					'Duplicate' happens when a pin is duplicated in the redemption report data from Tracfone

 MH20211018 : Added WHERE statement to Vendor Invoice Insert to avoid duplicate Invoices on Cellday_Accounting.Acct.VendorInvoice

 MH20240215 : Removed ParentItemID to accomidate activation fee
*****************************************************************************/
-- noqa: enable=all
CREATE OR ALTER PROC [Recon].[P_Upload_Tracfone_Redemption_PP]
AS
BEGIN
    BEGIN TRY
        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
        -- 1. insert txn
        DECLARE @Delimiter VARCHAR(16);
        SELECT @Delimiter = Delimiter
        FROM Recon.tblVendorSetup
        WHERE Id = 24;

        SET @Delimiter = ISNULL(@Delimiter, ',');
        TRUNCATE TABLE CellDayTemp.Tracfone.tblTransRedemptionRecon;
        --PS20171107 deleted extra columns							
        INSERT INTO CellDayTemp.Tracfone.tblTransRedemptionRecon
        (
            TF_SERIAL_NUM,
            Toss_Redemption_Date,
            [Description],
            Unit_Selling_Price,
            UserName
        )
        SELECT
            B.Chr1,
            CAST(REPLACE(REPLACE(B.Chr2, CHAR(10), ''), CHAR(13), '') AS DATE) AS Toss_Redemption_Date,
            B.Chr3,
            CASE
                WHEN LEN(B.Chr4) = 0
                    THEN 0.00
                ELSE CAST(REPLACE(REPLACE(REPLACE(B.Chr4, '$', ''), CHAR(10), ''), CHAR(13), '') AS DECIMAL(9, 2))		--MR20190919
            END AS [Unit_Selling_Price],
            REPLACE(REPLACE(B.Chr5, CHAR(10), ''), CHAR(13), '') AS UserName
        FROM Recon.tblPlainText AS A
        --CROSS APPLY Recon.fnEDITextParseByPass(@Delimiter,
        --                                  '"', DEFAULT,
        --                                  LTRIM(RTRIM(A.PlainText)),
        --                                  0) B
        CROSS APPLY dbo.SplitText(LTRIM(RTRIM(A.PlainText)), @Delimiter, '"') AS B
        WHERE ISDATE(B.Chr2) = 1;
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
            tu.Toss_Redemption_Date,
            tu.[Description],
            tu.Unit_Selling_Price,
            CAST(NULL AS INT) AS [Order_Id],
            CAST(NULL AS INT) AS [ProductSerialNum_ID],
            CAST(NULL AS VARCHAR(100)) AS [Status],
            tu.UserName
        INTO #tempProcess
        FROM CellDayTemp.Tracfone.tblTransRedemptionRecon AS tu;

        IF OBJECT_ID('tempdb..#Product_SerialNum_Preprocessed') IS NOT NULL
            BEGIN
                DROP TABLE #Product_SerialNum_Preprocessed;
            END;

        --Finds the first decommissioned and non-decommissioned record
        --PS20171107 replaced Batch_txt with SerialNumber_txt as TF_SERIAL_NUM matches on it
        SELECT
            ROW_NUMBER() OVER (PARTITION BY psn1.SerialNumber_txt ORDER BY psn1.Create_Dtm ASC) AS Rnum1,
            psn1.ProductSerialNum_ID AS Stat1SerialNum_ID,
            ROW_NUMBER() OVER (PARTITION BY psn0.SerialNumber_txt ORDER BY psn0.Create_Dtm ASC) AS Rnum0,
            psn0.ProductSerialNum_ID AS Stat0SerialNum_ID,
            tp.TF_SERIAL_NUM AS SerialNumber_txt
        INTO #Product_SerialNum_Preprocessed
        FROM #tempProcess AS tp
        --PS20171107 replaced Batch_txt with SerialNumber_txt as TF_SERIAL_NUM
        LEFT JOIN dbo.Product_SerialNum AS psn1 WITH (INDEX (IX_Product_SerialNum_serialNumber_Txt_StatusId))
            ON psn1.SerialNumber_txt = tp.TF_SERIAL_NUM AND psn1.Status_ID = 1
        LEFT JOIN dbo.Product_SerialNum AS psn0 WITH (INDEX (IX_Product_SerialNum_serialNumber_Txt_StatusId))
            ON psn0.SerialNumber_txt = tp.TF_SERIAL_NUM AND psn0.Status_ID = 0;

        --Adds the correct Product_SerialNum_ID to the pin reported as redeemed.
        UPDATE #tempProcess ---Product ID
        SET [ProductSerialNum_ID] = ISNULL(psnp1.Stat1SerialNum_ID, psnp0.Stat1SerialNum_ID)
        FROM #tempProcess AS tp
        LEFT JOIN #Product_SerialNum_Preprocessed AS psnp1
            ON
                psnp1.SerialNumber_txt = tp.TF_SERIAL_NUM
                AND tp.rnum = 1
                AND psnp1.Stat1SerialNum_ID IS NOT NULL
        LEFT JOIN #Product_SerialNum_Preprocessed AS psnp0
            ON
                psnp0.SerialNumber_txt = tp.TF_SERIAL_NUM
                AND tp.rnum = 1
                AND psnp0.Stat1SerialNum_ID IS NULL;

        --Grabs all the orders where the pins were redeemed.
        UPDATE #tempProcess
        SET
            Order_Id =
            (
                CASE
                    WHEN n.Void = 1 AND n.OrderTotal < 0
                        THEN ISNULL(sO.ID, o.ID)
                    ELSE o.ID
                END
            )
        FROM dbo.Order_No AS n
        LEFT JOIN dbo.Order_No AS s
            ON n.AuthNumber = CAST(s.Order_No AS NVARCHAR(50))
        LEFT JOIN dbo.Orders AS sO
            ON sO.Order_No = s.Order_No
        JOIN dbo.Orders AS o
            ON o.Order_No = n.Order_No
        JOIN dbo.Products AS p						--MH20240215
            ON o.Product_ID = p.Product_ID AND ISNULL(p.Product_Type, 0) IN (0, 1, 3)
        JOIN dbo.Product_SerialNum AS psn
            ON psn.Order_No = n.Order_No AND o.SKU = psn.SerialNumber_txt
        JOIN #tempProcess AS tp
            ON tp.ProductSerialNum_ID = psn.ProductSerialNum_ID
        --WHERE ISNULL(o.ParentItemID, 0) = 0;			--MH20240215 (removed)

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
        FROM #tempProcess AS tp
        LEFT JOIN dbo.Orders AS o
            ON o.ID = tp.Order_Id
        LEFT JOIN dbo.Order_No AS n
            ON n.Order_No = o.Order_No
        LEFT JOIN dbo.Order_Commission AS oc
            ON oc.Orders_ID = o.ID
        WHERE ISNULL(tp.Status, '') = ''
        GROUP BY
            tp.Order_Id,
            n.DateFilled,
            o.Price,
            o.DiscAmount,
            tp.ProductSerialNum_ID;

        --Inserts records into redemption log.
        INSERT INTO Cellday_History.Tracfone.tblTracTransRedemptionHistory
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
        FROM #tempProcess AS tp
        LEFT JOIN #tempTracFoneRedemtionLog AS ttrl
            ON ttrl.ProductSerialNum_ID = tp.ProductSerialNum_ID
        WHERE
            ISNULL(tp.[Status], '') = ''
            AND tp.ProductSerialNum_ID IS NOT NULL
            AND tp.rnum = 1
            AND NOT EXISTS
            (
                SELECT 1
                FROM Cellday_History.Tracfone.tblTracTransRedemptionHistory AS ttrh
                WHERE ttrh.ProductSerialNum_ID = tp.ProductSerialNum_ID
            );

        --Updates preexisting records with redemption data.
        UPDATE Cellday_History.Tracfone.tblTracTransRedemptionHistory
        SET
            Order_ID = ttrl.Order_Id,
            CollectionAmount = ttrl.OrderAmount,
            RedemptionDate = tp.Toss_Redemption_Date,
            ExposureDATE = ttrl.DateFilled
        FROM #tempProcess AS tp
        JOIN #tempTracFoneRedemtionLog AS ttrl
            ON ttrl.ProductSerialNum_ID = tp.ProductSerialNum_ID
        JOIN Cellday_History.Tracfone.tblTracTransRedemptionHistory AS ttrh
            ON ttrh.ProductSerialNum_ID = tp.ProductSerialNum_ID
        WHERE tp.rnum = 1;


        IF OBJECT_ID('tempdb..#Results') IS NOT NULL
            BEGIN
                DROP TABLE #Results;
            END;

        SELECT  -- noqa: ST06
            ISNULL(psn.ProductSerialNum_ID, -1) AS ProductSerialNum_ID,
            ISNULL(psn.Status_ID, 0) AS Status_ID,
            ISNULL(psn.SerialNumAvailable_Flg, 'N') AS SerialNumAvailable_Flg,
            tp.[Description],
            ISNULL(ttfr.Order_Id, -1) AS [OrderID],
            ttfr.DateFilled,
            tp.Unit_Selling_Price,
            ISNULL(ttfr.OrderAmount, 0) AS [TCetraAmount],
            tp.TF_SERIAL_NUM,
            tp.Toss_Redemption_Date,
            --BS20170627
            (ISNULL(ttfr.OrderAmount, 0) - tp.Unit_Selling_Price) AS [AmountDiff],
            DATEDIFF(DAY, ISNULL(ttfr.DateFilled, '1800-01-01'), ISNULL(tp.Toss_Redemption_Date, '1800-01-01')) AS [DateDiff],
            CASE
                WHEN tp.[Status] IS NULL -- noqa: ST02
                    THEN
                        CASE
                            WHEN tp.ProductSerialNum_ID IS NULL AND tp.rnum = 2
                                THEN 'Duplicate' --MB20180117
                            WHEN tp.ProductSerialNum_ID IS NULL AND tp.rnum = 1
                                THEN 'Missing'   --BS20170627									
                            WHEN psn.Status_ID = 1 AND psn.SerialNumAvailable_Flg = 'Y'
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
                ELSE
                    tp.[Status]
            END AS [Status],
            tp.UserName
        INTO #Results
        FROM #tempProcess AS tp
        --PS20171107 changed Batch_txt to SerialNumber_txt				
        LEFT JOIN dbo.Product_SerialNum AS psn WITH (INDEX (IX_Product_SerialNum_serialNumber_Txt_StatusId))
            ON psn.SerialNumber_txt = tp.TF_SERIAL_NUM
        LEFT JOIN #tempTracFoneRedemtionLog AS ttfr
            ON ttfr.ProductSerialNum_ID = psn.ProductSerialNum_ID;


        TRUNCATE TABLE CellDayTemp.Tracfone.tblTransRedemptionReconResult;
        --Inserts results into results table.
        --PS20171107 Deleted Product_code, PO_No, and Shipped_Date columns
        INSERT INTO CellDayTemp.Tracfone.tblTransRedemptionReconResult
        (
            ProductSerialNum_ID,
            Status_ID,
            SerialNumAvailable_Flg,
            [Description],
            OrderID,
            DateFilled,
            Unit_Selling_Price,
            TCetraAmount,
            TF_SERIAL_NUM,
            Toss_Redemption_Date,
            AmountDiff,
            [DateDiff],
            [Status]
        )
        SELECT
            r.ProductSerialNum_ID,
            r.Status_ID,
            r.SerialNumAvailable_Flg,
            r.[Description],
            r.OrderID,
            r.DateFilled,
            r.Unit_Selling_Price,
            r.TCetraAmount,
            r.TF_SERIAL_NUM,
            r.Toss_Redemption_Date,
            r.AmountDiff,
            r.[DateDiff],
            r.[Status]
        FROM #Results AS r

        INSERT INTO Cellday_Accounting.acct.VendorInvoice				--MR20190711
        (
            InvoiceNo,
            InvoiceDate,
            Process_Id
        )

        SELECT
        DISTINCT
            concat(YEAR(r.Toss_Redemption_Date), MONTH(r.Toss_Redemption_Date), DAY(r.Toss_Redemption_Date), 'TFredemptionPP') AS InvoiceNo,
            r.Toss_Redemption_Date AS InvoiceDate,
            11 AS Process_ID -- TracfoneRedemptionPP
        FROM #Results AS r
        WHERE
            r.Toss_Redemption_Date NOT IN (														--MH20211018
                SELECT vi.InvoiceDate
                FROM Cellday_Accounting.acct.VendorInvoice AS vi
                WHERE vi.InvoiceDate = r.Toss_Redemption_Date AND vi.Process_Id = 11
            )

        INSERT INTO Cellday_Accounting.acct.VendorDiscrepancies			--MR20190711
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
            11 AS process_ID,			--TracfoneRedemptionPP
            GETDATE() AS DateCreated,
            r.UserName AS UserCreated,
            CASE
                WHEN r.Status = 'Missing' THEN 14
                --WHEN r.Status = 'Duplicate' THEN 16
                WHEN r.status = 'Redeemed and Not Sold' THEN 20
                WHEN r.status = 'Uncaught Redeemption Before Sell Date' THEN 21
                WHEN r.status = 'Caught Redeemption Before Sell Date' THEN 22
                WHEN r.status = 'Product Needs Mapped' THEN 23
                --WHEN r.status = 'RTR' THEN 24
                ELSE 11
            END AS Discrepancy_ID,
            (r.AmountDiff) AS DiscrepancyAmt,
            r.TF_SERIAL_NUM AS TransactionID,
            r.OrderID AS Order_NO,
            vi.ID AS VendorInvoice_ID
        FROM #Results AS r
        JOIN Cellday_Accounting.acct.VendorInvoice AS vi
            ON
                vi.InvoiceDate = r.Toss_Redemption_Date
                AND vi.Process_Id = 11	 --TracfoneRedemptionPP
        WHERE r.Status NOT IN ('Success', 'RTR', 'Duplicate')


    END TRY
    BEGIN CATCH
        THROW;
    END CATCH;
END
-- noqa: disable=all
/
